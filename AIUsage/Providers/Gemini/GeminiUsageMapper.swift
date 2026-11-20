import Foundation

enum GeminiUsageMapper {
    static func map(response: HTTPResponse, now: Date, sourceLabel: String? = nil) throws -> ProviderSnapshot {
        let status = response.statusCode
        if status == 401 || status == 403 || (300..<400).contains(status) {
            throw GeminiAuthStore.signInRequired
        }
        if status == 429 {
            throw ProviderFailure(.rateLimited, "Gemini web usage is rate limited. Try again later.",
                retryAt: ProviderParsing.retryDate(from: response, now: now))
        }
        guard (200..<300).contains(status) else {
            throw ProviderFailure(status >= 500 ? .transient : .invalidResponse,
                "Gemini web usage request failed (\(status)).")
        }
        var text = String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<") { throw GeminiAuthStore.signInRequired }
        if text.hasPrefix(")]}'") { text = String(text.dropFirst(4)) }
        guard let rows = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]],
              let data = rows.compactMap({ $0["data"] as? [String: Any] }).first(where: { $0.keys.contains("viewer") }) else {
            throw changedResponse
        }
        if data["viewer"] is NSNull { throw GeminiAuthStore.signInRequired }
        guard let viewer = data["viewer"] as? [String: Any],
              let rpcs = viewer["rpcs"] as? [String: Any],
              let usage = rpcs["getUsageInfo"] as? [String: Any],
              let pools = usage["pools"] as? [[String: Any]] else { throw changedResponse }

        var warnings = ResponseSchemaWatch.httpHeaders(response, provider: .gemini, endpoint: "Gemini Web")
        warnings += ResponseSchemaWatch.jsonBodyDeprecation(usage, provider: .gemini, endpoint: "Gemini Web getUsageInfo")
        warnings += ResponseSchemaWatch.confirmedJSONKeys(
            in: usage,
            provider: .gemini,
            endpoint: "Gemini Web getUsageInfo"
        )
        if let tier = usage["subscriptionTier"] as? String,
           let enumWarning = ResponseSchemaWatch.confirmedEnum(
               tier,
               provider: .gemini,
               endpoint: "Gemini Web getUsageInfo",
               field: "subscriptionTier"
           ) {
            warnings.append(enumWarning)
        }

        let definitions: [(String, QuotaKind)] = [("GXU_FIVE_HOURLY", .session), ("GXU_WEEKLY", .weekly)]
        var windows = definitions.compactMap { type, kind -> QuotaWindow? in
            guard let pool = pools.first(where: { $0["poolType"] as? String == type }),
                  let fraction = ProviderParsing.double(pool["percentageUsed"]),
                  fraction.isFinite, fraction >= 0 else { return nil }
            let gxu = pool["gxu"] as? [String: Any]
            let remainingCount = QuotaDiscovery.number(gxu?["remaining"])
            let limitCount = QuotaDiscovery.number(gxu?["limit"] ?? gxu?["total"])
            return QuotaWindow(
                kind: kind,
                usedPercent: fraction * 100,
                resetsAt: ProviderParsing.date(gxu?["windowRefreshesAt"]),
                remainingCount: remainingCount,
                limitCount: limitCount
            )
        }
        var details: [ProviderUsageDetail] = []
        var sawOveragePoolCredits = false
        for pool in pools {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(
                in: pool,
                provider: .gemini,
                endpoint: "Gemini Web pool"
            )
            if let gxu = pool["gxu"] as? [String: Any] {
                warnings += ResponseSchemaWatch.confirmedJSONKeys(
                    in: gxu,
                    provider: .gemini,
                    endpoint: "Gemini Web gxu"
                )
            }
            guard let type = pool["poolType"] as? String else { continue }
            if let enumWarning = ResponseSchemaWatch.confirmedEnum(
                type,
                provider: .gemini,
                endpoint: "Gemini Web pool",
                field: "poolType"
            ) {
                warnings.append(enumWarning)
            }
            if type == "OVERAGE_CREDITS" {
                let creditsObj = (pool["credits"] as? [String: Any]) ?? (pool["overageCredits"] as? [String: Any])
                if let amount = QuotaDiscovery.number(
                    creditsObj?["creditsRemaining"]
                        ?? pool["creditsRemaining"]
                        ?? creditsObj?["remaining"]
                        ?? pool["remaining"]
                ) {
                    details.append(ProviderUsageDetail(
                        id: "gemini.overage.credits",
                        title: "Additional Credits",
                        value: "AI Credits \(QuotaWindow.formatCount(amount))"
                    ))
                    sawOveragePoolCredits = true
                }
                continue
            }
            guard !definitions.contains(where: { $0.0 == type }) else { continue }
            guard !(pool["percentageUsed"] is NSNull) else { continue }
            let ratio = QuotaDiscovery.number(pool["percentageUsed"])
            let gxu = pool["gxu"] as? [String: Any]
            if let window = QuotaDiscovery.window(id: "gemini.pool." + type, title: QuotaDiscovery.name(type),
                used: ratio.map { $0 * 100 }, reset: ProviderParsing.date(gxu?["windowRefreshesAt"])) {
                if !windows.contains(where: { $0.kind == window.kind }) { windows.append(window) }
            } else { details.append(QuotaDiscovery.notice(type)) }
        }
        if !sawOveragePoolCredits, usage["useOverageAiCredits"] as? Bool == false {
            details.append(ProviderUsageDetail(
                id: "gemini.overage.credits",
                title: "Additional Credits",
                value: "Off"
            ))
        }
        guard !windows.isEmpty else {
            throw ProviderFailure(.invalidResponse, "This Google account reports no Gemini web usage windows.")
        }
        // Only this tier's meaning is verified; do not invent a plan for unknown enums.
        let plan = usage["subscriptionTier"] as? String == "TIER1" ? "Google AI Pro" : nil
        return ProviderSnapshot(
            provider: .gemini,
            planName: plan,
            windows: windows,
            fetchedAt: now,
            credentialSource: sourceLabel,
            usageDetails: details,
            diagnosticWarnings: ResponseSchemaWatch.deduplicated(warnings)
        )
    }
    static var changedResponse: ProviderFailure {
        ProviderFailure(.invalidResponse, "Gemini web usage response changed. Update AI Usage.")
    }
}
