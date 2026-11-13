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
        let definitions: [(String, QuotaKind)] = [("GXU_FIVE_HOURLY", .session), ("GXU_WEEKLY", .weekly)]
        var windows = definitions.compactMap { type, kind -> QuotaWindow? in
            guard let pool = pools.first(where: { $0["poolType"] as? String == type }),
                  let fraction = ProviderParsing.double(pool["percentageUsed"]),
                  fraction.isFinite, fraction >= 0 else { return nil }
            let gxu = pool["gxu"] as? [String: Any]
            return QuotaWindow(kind: kind, usedPercent: fraction * 100,
                resetsAt: ProviderParsing.date(gxu?["windowRefreshesAt"]))
        }
        var notices: [ProviderUsageDetail] = []
        for pool in pools {
            guard let type = pool["poolType"] as? String, !definitions.contains(where: { $0.0 == type }) else { continue }
            guard !(pool["percentageUsed"] is NSNull) else { continue }
            let ratio = QuotaDiscovery.number(pool["percentageUsed"])
            if let window = QuotaDiscovery.window(id: "gemini.pool." + type, title: QuotaDiscovery.name(type),
                used: ratio.map { $0 * 100 }, reset: ProviderParsing.date((pool["gxu"] as? [String: Any])?["windowRefreshesAt"])) {
                if !windows.contains(where: { $0.kind == window.kind }) { windows.append(window) }
            } else { notices.append(QuotaDiscovery.notice(type)) }
        }
        guard !windows.isEmpty else {
            throw ProviderFailure(.invalidResponse, "This Google account reports no Gemini web usage windows.")
        }
        // Only this tier's meaning is verified; do not invent a plan for unknown enums.
        let plan = usage["subscriptionTier"] as? String == "TIER1" ? "Google AI Pro" : nil
        return ProviderSnapshot(provider: .gemini, planName: plan, windows: windows, fetchedAt: now, credentialSource: sourceLabel, usageDetails: notices)
    }
    static var changedResponse: ProviderFailure {
        ProviderFailure(.invalidResponse, "Gemini web usage response changed. Update AI Usage.")
    }
}
