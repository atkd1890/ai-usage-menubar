import Foundation

/// Claude Code's banked usage-limit reset grants (`cedar_ember`).
struct ClaudeResetGrants: Equatable, Sendable {
    struct Grant: Equatable, Sendable {
        let id: String
        let resetsLeft: Int
        let endsAt: Date?
        let usableNow: Bool?

        init(id: String, resetsLeft: Int, endsAt: Date?, usableNow: Bool? = nil) {
            self.id = id
            self.resetsLeft = resetsLeft
            self.endsAt = endsAt
            self.usableNow = usableNow
        }
    }

    let grants: [Grant]

    /// `nil` when the block is missing, malformed, or withheld from this
    /// client, so an unknown inventory is never shown as zero.
    static func parse(_ value: Any?) -> ClaudeResetGrants? {
        guard let block = ProviderParsing.object(value) else { return nil }
        let reason = ProviderParsing.string(block["ineligible_reason"])
        if block["eligible"] as? Bool != true,
           reason == "surface" || reason == "cli_version" {
            return nil
        }
        guard let rows = block["grants"] as? [Any] else {
            return reason == "no_grant" ? ClaudeResetGrants(grants: []) : nil
        }

        var grants: [Grant] = []
        for row in rows {
            guard let grant = ProviderParsing.object(row),
                  let id = ProviderParsing.string(grant["id"]),
                  let resetsLeft = ProviderParsing.double(grant["resets_left"]),
                  resetsLeft.isFinite,
                  resetsLeft < Double(Int32.max) else {
                return nil
            }
            grants.append(Grant(
                id: id,
                resetsLeft: max(0, Int(resetsLeft.rounded(.down))),
                endsAt: ProviderParsing.date(grant["ends_at"]),
                usableNow: grant["usable_now"] as? Bool
            ))
        }
        return ClaudeResetGrants(grants: grants)
    }

    func resets(at now: Date) -> UsageResets {
        var count = 0
        var usableCount = 0
        var sawUsableFlag = false
        var expirations: [Date] = []
        for grant in grants where grant.resetsLeft > 0 {
            if let endsAt = grant.endsAt, endsAt <= now { continue }
            count += grant.resetsLeft
            if let endsAt = grant.endsAt {
                expirations += Array(repeating: endsAt, count: grant.resetsLeft)
            }
            if let usableNow = grant.usableNow {
                sawUsableFlag = true
                if usableNow {
                    usableCount += grant.resetsLeft
                }
            }
        }
        return UsageResets(
            availableCount: count,
            expirations: expirations,
            usableCount: sawUsableFlag ? usableCount : nil
        )
    }
}

enum ClaudeUsageMapper {
    static func map(
        response: HTTPResponse,
        credentials: ClaudeOAuth,
        resets: UsageResets? = nil,
        now: Date
    ) throws -> ProviderSnapshot {
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "Claude usage request failed (\(response.statusCode))."
            )
        }
        let body = try ProviderParsing.object(from: response.body)
        var windows: [QuotaWindow] = []

        appendWindow(body["five_hour"], kind: .session, length: sessionLength, to: &windows)
        appendWindow(body["seven_day"], kind: .weekly, length: weekLength, to: &windows)
        appendWindow(body["seven_day_sonnet"], kind: .sonnet, length: weekLength, to: &windows)
        appendFable(body["limits"], to: &windows)
        var notices: [ProviderUsageDetail] = []
        for key in body.keys.sorted() where key.hasPrefix("seven_day_") && key != "seven_day_sonnet" {
            guard let quota = ProviderParsing.object(body[key]), quota["utilization"] != nil else { continue }
            if let window = QuotaDiscovery.window(id: "claude." + key,
                title: QuotaDiscovery.name(String(key.dropFirst(10))) + " · Weekly",
                used: QuotaDiscovery.number(quota["utilization"]), reset: ProviderParsing.date(quota["resets_at"])) {
                windows.append(window)
            } else { notices.append(QuotaDiscovery.notice(key)) }
        }
        for limit in ProviderParsing.array(body["limits"]) {
            guard limit["is_active"] as? Bool != false,
                  let scope = ProviderParsing.object(limit["scope"]) else { continue }
            let model = ProviderParsing.object(scope["model"])
            let surface = ProviderParsing.object(scope["surface"])
            guard let name = ProviderParsing.string(model?["display_name"]) ?? ProviderParsing.string(surface?["display_name"]),
                  name != "Fable" else { continue }
            let cadence = ProviderParsing.string(limit["kind"]) ?? "scoped"
            let id = "claude.scoped." + cadence + "." + name
            if let window = QuotaDiscovery.window(id: id, title: name + " · " + QuotaDiscovery.name(cadence),
                used: QuotaDiscovery.number(limit["percent"]), reset: ProviderParsing.date(limit["resets_at"])) {
                if !windows.contains(where: { $0.kind == window.kind }) { windows.append(window) }
            } else { notices.append(QuotaDiscovery.notice(id)) }
        }

        let warnings = schemaWarnings(in: body, response: response)

        let spend = ProviderParsing.object(body["spend"])
        let extraUsage = ProviderParsing.object(body["extra_usage"])
        let enabled = spend?["enabled"] as? Bool ?? extraUsage?["is_enabled"] as? Bool
        var details = notices
        if enabled != false, spend?["auto_reload"] as? Bool == true {
            details.append(ProviderUsageDetail(
                id: "claude.spend.auto_reload",
                title: "Auto-reload",
                value: "Enabled"
            ))
        }
        if extraUsage?["spend_limit_reached"] as? Bool == true {
            details.append(ProviderUsageDetail(
                id: "claude.extra_usage.limit_reached",
                title: "Extra usage cap",
                value: "Reached"
            ))
        }
        return ProviderSnapshot(
            provider: .claude,
            planName: planName(credentials),
            windows: windows,
            billingUsage: enabled == false ? nil : (monetarySpend(spend) ?? billingUsage(body["extra_usage"])),
            resets: resets,
            fetchedAt: now,
            usageScope: "Shared account limits · Claude Chat & Code",
            usageDetails: details,
            prepaidBalance: money(spend?["balance"]),
            additionalUsageEnabled: enabled,
            usageBreakdown: consumptionBreakdown(body, now: now),
            diagnosticWarnings: warnings
        )
    }

    private static func schemaWarnings(
        in body: [String: Any],
        response: HTTPResponse
    ) -> [ProviderDiagnosticWarning] {
        var warnings = ResponseSchemaWatch.httpHeaders(response, provider: .claude, endpoint: "Claude")
        warnings += ResponseSchemaWatch.jsonBodyDeprecation(body, provider: .claude, endpoint: "Claude")
        warnings += ResponseSchemaWatch.confirmedJSONKeys(in: body, provider: .claude, endpoint: "Claude")

        for key in body.keys.sorted() where ["five_hour", "seven_day", "seven_day_sonnet"].contains(key) || key.hasPrefix("seven_day_") && key != "seven_day_breakdown" {
            if let window = ProviderParsing.object(body[key]) {
                warnings += ResponseSchemaWatch.confirmedJSONKeys(in: window, provider: .claude, endpoint: "Claude window")
            }
        }
        if let extraUsage = ProviderParsing.object(body["extra_usage"]) {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(in: extraUsage, provider: .claude, endpoint: "Claude extra_usage")
        }
        if let spend = ProviderParsing.object(body["spend"]) {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(in: spend, provider: .claude, endpoint: "Claude spend")
        }
        if let cedar = ProviderParsing.object(body["cedar_ember"]) {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(in: cedar, provider: .claude, endpoint: "Claude cedar_ember")
            for grant in ProviderParsing.array(cedar["grants"]) {
                warnings += ResponseSchemaWatch.confirmedJSONKeys(in: grant, provider: .claude, endpoint: "Claude cedar_ember grant")
            }
        }
        for limit in ProviderParsing.array(body["limits"]) {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(in: limit, provider: .claude, endpoint: "Claude limit")
        }
        if let breakdown = ProviderParsing.object(body["seven_day_breakdown"]) {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(in: breakdown, provider: .claude, endpoint: "Claude breakdown")
            for row in ProviderParsing.array(breakdown["rows"]) {
                warnings += ResponseSchemaWatch.confirmedJSONKeys(in: row, provider: .claude, endpoint: "Claude breakdown row")
            }
        }
        return ResponseSchemaWatch.deduplicated(warnings)
    }

    static func consumptionBreakdown(_ body: [String: Any], now: Date) -> ConsumptionBreakdown? {
        guard let data = ProviderParsing.object(body["seven_day_breakdown"]),
              let rows = data["rows"] as? [[String: Any]], !rows.isEmpty,
              let asOf = ProviderParsing.date(data["as_of"]), asOf <= now.addingTimeInterval(300),
              let start = ProviderParsing.date(data["window_started_at"]), start <= asOf else { return nil }
        if let reset = ProviderParsing.object(body["seven_day"]).flatMap({ ProviderParsing.date($0["resets_at"]) }),
           (asOf >= reset || now >= reset || start >= reset || start < reset.addingTimeInterval(-604800 - 300)) { return nil }
        var seen = Set<String>()
        var shares: [ConsumptionShare] = []
        for row in rows {
            guard let key = ProviderParsing.string(row["key"]), !key.isEmpty, seen.insert(key).inserted,
                  let title = ProviderParsing.string(row["display_name"]), !title.isEmpty,
                  let percent = ProviderParsing.double(row["percent"]), percent.isFinite, (0...100).contains(percent) else { return nil }
            shares.append(ConsumptionShare(id: key, title: key == "claude_code" ? "Code" : title, percent: percent))
        }
        let total = shares.reduce(0) { $0 + $1.percent }
        let weeklyUsed = ProviderParsing.object(body["seven_day"]).flatMap { ProviderParsing.double($0["utilization"]) }
        guard abs(total - 100) <= 1 || (total == 0 && weeklyUsed == 0) else { return nil }
        return ConsumptionBreakdown(shares: shares, asOf: asOf)
    }

    static func resetGrants(from response: HTTPResponse) -> ClaudeResetGrants? {
        guard (200..<300).contains(response.statusCode),
              let body = try? ProviderParsing.object(from: response.body) else {
            return nil
        }
        return ClaudeResetGrants.parse(body["cedar_ember"])
    }

    /// Anthropic now sells the 5x and 20x Max plans as Max and Ultra.
    static func planName(_ credentials: ClaudeOAuth) -> String? {
        guard var raw = credentials.subscriptionType?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if raw.lowercased().hasPrefix("claude_") {
            raw.removeFirst("claude_".count)
        }
        let base = ProviderParsing.titleCaseIdentifier(raw)
        let tier = credentials.rateLimitTier?.lowercased() ?? ""
        if base == "Ultra" ||
            (base == "Max" && (tier.contains("ultra") || tier.contains("20x"))) {
            return "Ultra"
        }
        if base == "Max" {
            return "Max"
        }
        guard let range = tier.range(of: #"\d+x"#, options: .regularExpression)
        else {
            return base
        }
        return "\(base) \(tier[range])"
    }

    private static let sessionLength: TimeInterval = 5 * 3_600
    private static let weekLength: TimeInterval = 7 * 86_400

    private static func appendWindow(
        _ value: Any?,
        kind: QuotaKind,
        length: TimeInterval,
        to windows: inout [QuotaWindow]
    ) {
        guard
            let object = ProviderParsing.object(value),
            let used = ProviderParsing.double(object["utilization"])
        else {
            return
        }
        let reset = ProviderParsing.date(object["resets_at"])
        windows.append(QuotaWindow(
            kind: kind,
            usedPercent: used,
            resetsAt: reset,
            startsAt: ProviderParsing.windowStart(endingAt: reset, length: length)
        ))
    }

    private static func appendFable(
        _ value: Any?,
        to windows: inout [QuotaWindow]
    ) {
        guard let limits = value as? [Any] else { return }
        for item in limits {
            guard
                let limit = ProviderParsing.object(item),
                ProviderParsing.string(limit["kind"]) == "weekly_scoped",
                let scope = ProviderParsing.object(limit["scope"]),
                let model = ProviderParsing.object(scope["model"]),
                ProviderParsing.string(model["display_name"]) == "Fable",
                let used = ProviderParsing.double(limit["percent"])
            else {
                continue
            }
            let reset = ProviderParsing.date(limit["resets_at"])
            windows.append(QuotaWindow(
                kind: .fable,
                usedPercent: used,
                resetsAt: reset,
                startsAt: ProviderParsing.windowStart(endingAt: reset, length: weekLength)
            ))
            return
        }
    }

    /// Anthropic names these fields "credits" but reports minor units of the
    /// account's billing currency (cents for USD, unless `decimal_places`
    /// says otherwise).
    /// Native OAuth `spend` uses typed money, not abstract AI credit counts.
    static func money(_ value: Any?) -> MonetaryBalance? {
        guard let object = ProviderParsing.object(value),
              let minor = ProviderParsing.double(object["amount_minor"]), minor.isFinite, minor >= 0,
              let exponent = ProviderParsing.double(object["exponent"]), exponent.isFinite,
              exponent.rounded() == exponent, (0...4).contains(exponent),
              let currency = ProviderParsing.string(object["currency"]),
              currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { return nil }
        return MonetaryBalance(amount: minor / pow(10, exponent), currencyCode: currency)
    }
    private static func monetarySpend(_ spend: [String: Any]?) -> BillingUsage? {
        guard let spend, let used = money(spend["used"]) else { return nil }
        if let limit = money(spend["limit"]), limit.currencyCode == used.currencyCode, limit.amount > 0 {
            return .boundedSpend(usedAmount: used.amount, limitAmount: limit.amount, currencyCode: used.currencyCode)
        }
        guard used.amount > 0 else { return nil }
        return .unboundedSpend(usedAmount: used.amount, currencyCode: used.currencyCode)
    }

    private static func billingUsage(_ value: Any?) -> BillingUsage? {
        guard
            let object = ProviderParsing.object(value),
            object["is_enabled"] as? Bool == true,
            let usedMinor = ProviderParsing.double(object["used_credits"])
        else {
            return nil
        }

        let currency = ProviderParsing.string(object["currency"])?
            .uppercased() ?? "USD"
        let decimals = ProviderParsing.double(object["decimal_places"])
            .map { min(max($0.rounded(), 0), 4) } ?? 2
        let divisor = pow(10, decimals)
        let usedAmount = usedMinor.rounded() / divisor
        if let limitMinor = ProviderParsing.double(object["monthly_limit"]),
           limitMinor > 0 {
            return .boundedSpend(
                usedAmount: usedAmount,
                limitAmount: limitMinor.rounded() / divisor,
                currencyCode: currency
            )
        }
        guard usedAmount > 0 else {
            return nil
        }
        return .unboundedSpend(
            usedAmount: usedAmount,
            currencyCode: currency
        )
    }
}
