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
        var overageDetails: [ProviderUsageDetail] = []
        var notices: [ProviderUsageDetail] = []
        for field in fields where field.number == 3 {
            guard let bytes = field.bytes, let pool = try? GeminiProtobuf.fields(bytes) else { continue }
            warnings += ResponseSchemaWatch.confirmedProtobufFields(
                pool,
                provider: .gemini,
                endpoint: "Gemini Native pool"
            )
            guard let type = pool.first(where: { $0.number == 1 })?.integer else { continue }
            if let enumWarning = ResponseSchemaWatch.confirmedEnum(
                String(type),
                provider: .gemini,
                endpoint: "Gemini Native pool",
                field: "pool_type"
            ) {
                warnings.append(enumWarning)
            }
            if type == 3 {
                guard let creditsData = pool.first(where: { $0.number == 3 })?.bytes,
                      let credits = try? GeminiProtobuf.fields(creditsData) else {
                    if pool.contains(where: { $0.number > 1 && $0.bytes?.isEmpty == false }) {
                        notices.append(QuotaDiscovery.notice("Gemini pool \(type)"))
                    }
                    continue
                }
                warnings += ResponseSchemaWatch.confirmedProtobufFields(
                    credits,
                    provider: .gemini,
                    endpoint: "Gemini Native OverageCreditPool"
                )
                if overageDetails.isEmpty {
                    let expiresAt = credits.first(where: { $0.number == 1 })?.bytes.flatMap {
                        decodeTimestamp($0, allowEpochZero: false)
                    }
                    let creditsRemaining: Double? = credits.first(where: { $0.number == 2 })?.integer.flatMap {
                        let signed = Int64(bitPattern: $0)
                        return signed >= 0 ? Double(signed) : nil
                    }
                    let useOverage: Bool? = credits.first(where: { $0.number == 3 })?.integer.flatMap {
                        switch $0 {
                        case 0: false
                        case 1: true
                        default: nil
                        }
                    }
                    overageDetails = GeminiUsageMapper.overageCreditDetails(
                        creditsRemaining: creditsRemaining,
                        useOverage: useOverage,
                        expiresAt: expiresAt
                    )
                }
                continue
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
            let reset = gxu.first(where: { $0.number == 1 })?.bytes.flatMap { decodeTimestamp($0) }
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
        guard !windows.isEmpty || !overageDetails.isEmpty else { throw GeminiUsageMapper.changedResponse }
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
            usageDetails: overageDetails + notices,
            diagnosticWarnings: ResponseSchemaWatch.deduplicated(warnings)
        )
    }

    private static func decodeTimestamp(_ data: Data, allowEpochZero: Bool = true) -> Date? {
        guard let time = try? GeminiProtobuf.fields(data),
              let seconds = time.first(where: { $0.number == 1 })?.integer else {
            return nil
        }
        let nanos = time.first(where: { $0.number == 2 })?.integer ?? 0
        guard seconds <= UInt64(Int64.max), nanos < 1_000_000_000 else { return nil }
        guard allowEpochZero || seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }
}
