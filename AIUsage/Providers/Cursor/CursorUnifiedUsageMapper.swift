import Foundation

/// Verified against the user's unified Plus responses. Included cents are quota
/// weights, not a cash balance. resetCounter is deliberately not reset inventory.
enum CursorUnifiedUsageMapper {
    static func map(legacy: ProviderSnapshot, dashboard: HTTPResponse?, shared: HTTPResponse?,
                    isMerged: Bool, now: Date) throws -> ProviderSnapshot {
        func object(_ response: HTTPResponse?) -> [String: Any]? {
            guard let response, response.statusCode == 200 else { return nil }
            return try? ProviderParsing.object(from: response.body)
        }
        func number(_ value: Any?) -> Double? {
            guard let n = ProviderParsing.double(value), n.isFinite, n >= 0 else { return nil }
            return n
        }
        let status = object(dashboard)
        let sand = object(shared)
        guard isMerged || sand?["isUnified"] as? Bool == true else { return legacy }
        let available = status?["availability"] as? String == "available"
        let weekly = available ? ProviderParsing.object(status?["weeklyIncludedUsage"]) : nil
        var window: QuotaWindow?
        if let weekly, let used = number(weekly["usedCents"]),
           let budget = number(weekly["budgetCents"]), budget > 0,
           let start = ProviderParsing.date(weekly["periodStart"]), start <= now,
           let reset = ProviderParsing.date(weekly["resetsAt"]), reset > now {
            window = QuotaWindow(kind: .weekly, usedPercent: min(used / budget * 100, 100), resetsAt: reset)
        } else if let sand, sand["isUnified"] as? Bool == true,
                  let percent = number(sand["usagePercent"]),
                  let reset = ProviderParsing.date(sand["nextResetTimestampUtc"]), reset > now {
            window = QuotaWindow(kind: .weekly, usedPercent: min(percent, 100), resetsAt: reset)
        } else if let previous = legacy.windows.first(where: { $0.kind == .totalUsage }),
                  let reset = previous.resetsAt, reset > now {
            window = QuotaWindow(kind: .weekly, usedPercent: previous.usedPercent, resetsAt: reset)
        }
        guard let window else { throw ProviderFailure(.invalidResponse, "X Subscription weekly usage is unavailable.") }
        var products: [UnifiedProductUsage] = []
        if weekly != nil, let raw = status?["weeklyIncludedUsageByProduct"] as? [[String: Any]],
           let total = number(weekly?["usedCents"]) {
            var seen = Set<String>()
            let parsed = raw.compactMap { row -> UnifiedProductUsage? in
                guard let name = ProviderParsing.string(row["product"]), !name.isEmpty,
                      seen.insert(name).inserted, let cents = number(row["cents"]) else { return nil }
                return UnifiedProductUsage(product: name, usedCents: cents)
            }
            // Never show a partial breakdown as if it accounts for the entire pool.
            if parsed.count == raw.count, abs(parsed.reduce(0) { $0 + $1.usedCents } - total) <= 1 {
                products = parsed.sorted { $0.usedCents > $1.usedCents }
            }
        }
        var billing: BillingUsage?
        var billingReset: Date?
        var billingEnabled: Bool?
        if available, let monthly = ProviderParsing.object(status?["monthlyUsage"]),
           let used = number(monthly["usedCents"]), let limit = number(monthly["limitCents"]),
           let start = ProviderParsing.date(monthly["periodStart"]), start <= now,
           let reset = ProviderParsing.date(monthly["resetsAt"]), reset > now {
            billing = .boundedSpend(usedAmount: used / 100, limitAmount: limit / 100, currencyCode: "USD")
            billingReset = reset
            billingEnabled = (monthly["additionalUsageOff"] as? Bool).map { !$0 }
        }
        return ProviderSnapshot(provider: .cursor, planName: legacy.planName, windows: [window],
            billingUsage: billing, fetchedAt: now,
            xSubscription: XSubscriptionUsage(products: products,
                prepaidDollars: number(sand?["prepaidAvailableCents"]).map { $0 / 100 },
                additionalUsageResetsAt: billingReset, additionalUsageEnabled: billingEnabled,
                additionalUsageUnavailable: billing == nil),
            credentialSource: "Shared Cursor & Grok usage · Cursor app")
    }
}
