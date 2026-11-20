import Foundation

enum CopilotUsageMapper {
    static func map(
        response: HTTPResponse,
        now: Date
    ) throws -> ProviderSnapshot {
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "Copilot usage request failed (\(response.statusCode))."
            )
        }

        let body = try ProviderParsing.object(from: response.body)
        let reset = resetDate(body)
        let snapshots = ProviderParsing.object(body["quota_snapshots"])
        var windows: [QuotaWindow] = []

        if let credits = quotaWindow(
            snapshots?["premium_interactions"],
            kind: .credits,
            resetsAt: reset
        ) {
            windows.append(credits)
        }
        if let chat = quotaWindow(
            snapshots?["chat"],
            kind: .chat,
            resetsAt: reset
        ) {
            windows.append(chat)
        }
        if let completions = quotaWindow(
            snapshots?["completions"],
            kind: .completions,
            resetsAt: reset
        ) {
            windows.append(completions)
        }

        var notices: [ProviderUsageDetail] = []
        for key in (snapshots ?? [:]).keys.sorted() where !["chat", "completions", "premium_interactions"].contains(key) {
            guard let bucket = ProviderParsing.object(snapshots?[key]) else { continue }
            if let window = quotaWindow(bucket, kind: .additional(id: "copilot." + key, title: QuotaDiscovery.name(key)), resetsAt: reset) {
                windows.append(window)
            } else if bucket["has_quota"] as? Bool != false && bucket["unlimited"] as? Bool != true &&
                QuotaDiscovery.number(bucket["entitlement"]) != -1 && QuotaDiscovery.number(bucket["entitlement"]) != 0 {
                notices.append(QuotaDiscovery.notice(key))
            }
        }
        if windows.isEmpty {
            let limited = ProviderParsing.object(body["limited_user_quotas"])
            let monthly = ProviderParsing.object(body["monthly_quotas"])
            if let chat = legacyWindow(
                remaining: limited?["chat"],
                total: monthly?["chat"],
                kind: .chat,
                resetsAt: reset
            ) {
                windows.append(chat)
            }
            if let completions = legacyWindow(
                remaining: limited?["completions"],
                total: monthly?["completions"],
                kind: .completions,
                resetsAt: reset
            ) {
                windows.append(completions)
            }
        }

        let isOrganizationSeat = body["token_based_billing"] as? Bool == true
        guard !windows.isEmpty || isOrganizationSeat else {
            throw ProviderFailure(
                .invalidResponse,
                "Copilot usage data is unavailable for this account."
            )
        }

        let overagePermitted = ProviderParsing.object(snapshots?["premium_interactions"])?["overage_permitted"] as? Bool
        return ProviderSnapshot(
            provider: .copilot,
            planName: planName(body["copilot_plan"], accessTypeSKU: body["access_type_sku"]),
            windows: windows,
            fetchedAt: now,
            usageScope: "Account usage · quotas and credits shown separately",
            usageDetails: quotaAllowanceDetails(body) + notices,
            additionalUsageEnabled: overagePermitted
        )
    }

    static func quotaAllowanceDetails(_ body: [String: Any]) -> [ProviderUsageDetail] {
        guard let snapshots = ProviderParsing.object(body["quota_snapshots"]) else {
            return []
        }
        var details: [ProviderUsageDetail] = []
        for (key, title) in [
            ("premium_interactions", "Premium requests"),
            ("chat", "Chat messages"),
            ("completions", "Code completions")
        ] {
            guard let bucket = ProviderParsing.object(snapshots[key]),
                  bucket["has_quota"] as? Bool != false,
                  bucket["unlimited"] as? Bool != true else { continue }
            if let overage = ProviderParsing.double(bucket["overage_count"]),
               overage.isFinite, overage > 0 {
                details.append(ProviderUsageDetail(
                    id: "copilot.\(key).overage",
                    title: "\(title) overage",
                    value: "\(Int(overage.rounded()))"
                ))
            }
        }
        return details
    }

    /// Credits belong to the returned bucket. Do not add Chat, Completions and
    /// Premium together: the endpoint does not guarantee disjoint pools.
    static func creditDetails(_ body: [String: Any]) -> [ProviderUsageDetail] {
        guard let snapshots = ProviderParsing.object(body["quota_snapshots"]) else { return [] }
        return [("premium_interactions", "Premium"), ("chat", "Chat"), ("completions", "Completions")].compactMap { key, title in
            guard let bucket = ProviderParsing.object(snapshots[key]),
                  bucket["has_quota"] as? Bool != false,
                  let used = ProviderParsing.double(bucket["credits_used"]), used.isFinite, used >= 0 else { return nil }
            let tokenBilling = body["token_based_billing"] as? Bool == true || bucket["token_based_billing"] as? Bool == true
            guard tokenBilling || bucket["unlimited"] as? Bool == true || used > 0 else { return nil }
            return ProviderUsageDetail(id: key + "-credits", title: title + " credits used",
                value: used.formatted(.number.precision(.fractionLength(0...2))))
        }
    }

    private static func quotaWindow(
        _ value: Any?,
        kind: QuotaKind,
        resetsAt: Date?
    ) -> QuotaWindow? {
        guard let bucket = ProviderParsing.object(value), bucket["has_quota"] as? Bool != false else { return nil }
        let entitlement = ProviderParsing.double(bucket["entitlement"])
        let remaining = ProviderParsing.double(bucket["remaining"]) ?? ProviderParsing.double(bucket["quota_remaining"])

        let isUnlimited = bucket["unlimited"] as? Bool == true ||
            entitlement == -1 ||
            remaining == -1
        if isUnlimited {
            if [QuotaKind.chat, .completions].contains(kind) {
                return QuotaWindow(
                    kind: kind,
                    usedPercent: 0,
                    resetsAt: nil,
                    isUnlimited: true
                )
            }
            return nil
        }
        if entitlement == 0 {
            return nil
        }

        let usedPercent: Double
        if let percentRemaining = ProviderParsing.double(
            bucket["percent_remaining"]
        ) {
            guard percentRemaining.isFinite else { return nil }
            usedPercent = clampPercent(100 - percentRemaining)
        } else if let entitlement, entitlement > 0, let remaining {
            usedPercent = clampPercent(
                100 - (remaining / entitlement) * 100
            )
        } else {
            return nil
        }
        let bucketReset = parseResetDate(bucket["quota_reset_at"]) ?? resetsAt
        return QuotaWindow(
            kind: kind,
            usedPercent: usedPercent,
            resetsAt: bucketReset,
            remainingCount: remaining,
            limitCount: entitlement
        )
    }

    private static func legacyWindow(
        remaining: Any?,
        total: Any?,
        kind: QuotaKind,
        resetsAt: Date?
    ) -> QuotaWindow? {
        guard let total = ProviderParsing.double(total), total > 0,
              let remaining = ProviderParsing.double(remaining) else {
            return nil
        }
        return QuotaWindow(
            kind: kind,
            usedPercent: clampPercent(
                ((total - remaining) / total) * 100
            ),
            resetsAt: resetsAt,
            remainingCount: remaining,
            limitCount: total
        )
    }

    private static func resetDate(_ body: [String: Any]) -> Date? {
        for key in ["quota_reset_date_utc", "quota_reset_date", "limited_user_reset_date"] {
            if let date = parseResetDate(body[key]) {
                return date
            }
        }
        return nil
    }

    private static func parseResetDate(_ raw: Any?) -> Date? {
        if let number = ProviderParsing.double(raw), (!number.isFinite || number <= 0) {
            return nil
        }
        if let date = ProviderParsing.date(raw) {
            return date
        }
        guard let value = ProviderParsing.string(raw) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func planName(_ value: Any?, accessTypeSKU: Any?) -> String? {
        if ProviderParsing.string(accessTypeSKU)?.lowercased() == "free_limited_copilot" {
            return "Free"
        }
        guard let raw = ProviderParsing.string(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return ProviderParsing.titleCaseIdentifier(raw)
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
