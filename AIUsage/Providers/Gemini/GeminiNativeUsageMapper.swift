import Foundation

enum GeminiNativeUsageMapper {
    static func map(response: HTTPResponse, now: Date, accountLabel: String?) throws -> ProviderSnapshot {
        if response.statusCode == 401 { throw GeminiNativeAuthStore.signInRequired }
        if response.statusCode == 403 {
            throw ProviderFailure(.authentication, "Gemini app quota access was denied. Check the signed-in account and permissions.")
        }
        if response.statusCode == 429 {
            throw ProviderFailure(.rateLimited, "Gemini native usage is rate limited.",
                retryAt: ProviderParsing.retryDate(from: response, now: now))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(response.statusCode >= 500 ? .transient : .invalidResponse,
                "Gemini native usage request failed (\(response.statusCode)).")
        }
        let fields: [GeminiProtobuf.Field]
        do { fields = try GeminiProtobuf.fields(response.body) }
        catch { throw GeminiUsageMapper.changedResponse }

        var warnings = ResponseSchemaWatch.httpHeaders(response, provider: .gemini, endpoint: "Gemini Native")
        warnings += ResponseSchemaWatch.confirmedProtobufFields(
            fields,
            provider: .gemini,
            endpoint: "Gemini Native"
        )
        if let tier = fields.first(where: { $0.number == 2 })?.integer,
           let enumWarning = ResponseSchemaWatch.confirmedEnum(
               String(tier),
               provider: .gemini,
               endpoint: "Gemini Native",
               field: "user_tier"
           ) {
            warnings.append(enumWarning)
        }

        var quotas: [QuotaKind: QuotaWindow] = [:]
        var notices: [ProviderUsageDetail] = []
        for field in fields where field.number == 3 {
            guard let bytes = field.bytes, let pool = try? GeminiProtobuf.fields(bytes) else { continue }
            warnings += ResponseSchemaWatch.confirmedProtobufFields(
                pool,
                provider: .gemini,
                endpoint: "Gemini Native pool"
            )
            guard let type = pool.first(where: { $0.number == 1 })?.integer else { continue }
            if type == 3 {
                if let notice = ResponseSchemaWatch.confirmedNotice(
                    id: "schema.added.gemini.overage_credits",
                    provider: .gemini,
                    endpoint: "Gemini Native pool",
                    kind: .schemaAdded,
                    summary: "Gemini Native OVERAGE_CREDITS pool detected",
                    detail: "OverageCreditPool appeared in GetUsageInfo; inspect wire fields to display AI credits.",
                    signature: "schema.added.gemini.overage_credits"
                ) {
                    warnings.append(notice)
                }
                continue
            }
            if let enumWarning = ResponseSchemaWatch.confirmedEnum(
                String(type),
                provider: .gemini,
                endpoint: "Gemini Native pool",
                field: "pool_type"
            ) {
                warnings.append(enumWarning)
            }
            guard let gxuData = pool.first(where: { $0.number == 2 })?.bytes,
                  let gxu = try? GeminiProtobuf.fields(gxuData),
                  let used = gxu.first(where: { $0.number == 2 })?.floating,
                  used.isFinite, used >= 0 else {
                if pool.contains(where: { $0.number > 1 && $0.bytes?.isEmpty == false }) {
                    notices.append(QuotaDiscovery.notice("Gemini pool \(type)"))
                }
                continue
            }
            warnings += ResponseSchemaWatch.confirmedProtobufFields(
                gxu,
                provider: .gemini,
                endpoint: "Gemini Native GxuPool"
            )
            let kind: QuotaKind
            switch type { case 1: kind = .session; case 2: kind = .weekly; default: kind = .additional(id: "gemini.pool.\(type)", title: "Gemini · Quota \(type)") }
            var reset: Date?
            if let timestamp = gxu.first(where: { $0.number == 1 })?.bytes,
               let time = try? GeminiProtobuf.fields(timestamp),
               let seconds = time.first(where: { $0.number == 1 })?.integer {
                let nanos = time.first(where: { $0.number == 2 })?.integer ?? 0
                if seconds <= UInt64(Int64.max), nanos < 1_000_000_000 {
                    reset = Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
                }
            }
            let remainingCount = gxu.first(where: { $0.number == 5 })?.integer.map { Double($0) }
            let limitCount = gxu.first(where: { $0.number == 6 })?.integer.map { Double($0) }
            // Do not combine duplicate pool records or invent missing percentages.
            if quotas[kind] == nil {
                quotas[kind] = QuotaWindow(
                    kind: kind,
                    usedPercent: used * 100,
                    resetsAt: reset,
                    remainingCount: remainingCount,
                    limitCount: limitCount
                )
            }
        }
        let windows = [QuotaKind.session, .weekly].compactMap { quotas[$0] } + quotas.keys
            .filter { $0 != .session && $0 != .weekly }.sorted { $0.rawValue < $1.rawValue }.compactMap { quotas[$0] }
        guard !windows.isEmpty else { throw GeminiUsageMapper.changedResponse }
        // Installed Gemini's SwiftProtobuf name map identifies user_tier=2 as
        // TIER1, the verified Pro tier. Unknown values stay unlabeled.
        let plan = fields.first(where: { $0.number == 2 })?.integer == 2 ? "Google AI Pro" : nil
        return ProviderSnapshot(
            provider: .gemini,
            planName: plan,
            windows: windows,
            fetchedAt: now,
            credentialSource: "Gemini app",
            accountLabel: accountLabel,
            usageDetails: notices,
            diagnosticWarnings: ResponseSchemaWatch.deduplicated(warnings)
        )
    }
}
