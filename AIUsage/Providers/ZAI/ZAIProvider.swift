import Foundation

actor ZAIProvider: UsageProvider {
    nonisolated let id = ProviderID.zai
    private let http: any HTTPClient
    private let method: @Sendable () -> ProviderLoginMethod
    private let credential: @Sendable (ProviderLoginMethod) throws -> ZAICredential
    init(http: (any HTTPClient)? = nil,
         method: @escaping @Sendable () -> ProviderLoginMethod = { .selected(for: .zai) },
         credential: @escaping @Sendable (ProviderLoginMethod) throws -> ZAICredential = { try ZAIAuthStore().load($0) }) {
        self.http = http ?? GeminiReadOnlyHTTPClient(allowedHosts: ["api.z.ai", "zcode.z.ai"])
        self.method = method; self.credential = credential
    }
    func fetch() async throws -> ProviderSnapshot {
        let auth = try credential(method())
        func request(_ host: String, _ path: String, _ token: String) -> HTTPRequest {
            HTTPRequest(method: .get, url: URL(string: "https://" + host + path)!,
                headers: ["Authorization": token.lowercased().hasPrefix("bearer ") ? token : "Bearer " + token, "Accept": "application/json"], body: nil)
        }
        let subscription = try await http.send(request("api.z.ai", "/api/biz/subscription/list", auth.token))
        _ = try Self.envelope(subscription)
        let account = try? await http.send(request("api.z.ai", "/api/biz/customer/getCustomerInfo", auth.token))
        let quota = try? await http.send(request("api.z.ai", "/api/monitor/usage/quota/limit", auth.token))
        if let quota {
            do { _ = try Self.envelope(quota) }
            catch let failure as ProviderFailure where failure.kind == .authentication || failure.kind == .rateLimited {
                throw failure
            } catch {}
        }
        var start: HTTPResponse?
        if let token = auth.zcodeToken, let version = auth.startHeaders["X-ZCode-App-Version"] {
            var balanceRequest = request("zcode.z.ai", "/api/v1/zcode-plan/billing/balance?app_version=" + version, token)
            for (key, value) in auth.startHeaders { balanceRequest.headers[key] = value }
            start = try? await http.send(balanceRequest)
        }
        return try Self.map(subscription: subscription, quota: quota, start: start, auth: auth, account: account)
    }
    static func date(_ value: Any?) -> Date? {
        if let number = QuotaDiscovery.number(value) { return number > 0 ? ProviderParsing.date(number) : nil }
        guard let text = value as? String, text.range(of: #"(Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil else { return nil }
        return ProviderParsing.date(text)
    }
    static func envelope(_ response: HTTPResponse) throws -> [String: Any] {
        if response.statusCode == 429 { throw ProviderFailure(.rateLimited, "Z.ai usage is rate limited.") }
        guard response.body.count < 2_000_000, let root = try? ProviderParsing.object(from: response.body) else {
            throw ProviderFailure(.invalidResponse, "Z.ai usage response changed.")
        }
        let code = QuotaDiscovery.number(root["code"])
        if [401,403].contains(response.statusCode) || code == 401 || code == 403 {
            throw ProviderFailure(.authentication, "Z.ai rejected the selected login. Sign in to that source again.")
        }
        guard response.statusCode == 200, root["success"] as? Bool != false, code == 0 || code == 200 else {
            throw ProviderFailure(.invalidResponse, "Z.ai usage is unavailable.")
        }
        return root
    }
    static func map(subscription: HTTPResponse, quota: HTTPResponse?, start: HTTPResponse?, auth: ZAICredential, account: HTTPResponse? = nil, now: Date = Date()) throws -> ProviderSnapshot {
        let root = try envelope(subscription)
        guard let plans = root["data"] as? [[String: Any]] else { throw ProviderFailure(.invalidResponse, "Z.ai subscription response changed.") }
        var warnings = ResponseSchemaWatch.confirmedJSONKeys(in: root, provider: .zai, endpoint: "Z.ai envelope")
        warnings += ResponseSchemaWatch.httpHeaders(subscription, provider: .zai, endpoint: "Z.ai subscriptions")
        var details: [ProviderUsageDetail] = [], windows: [QuotaWindow] = []
        var activeCodingPlans: [String] = []
        var activePlans: [String] = []
        var startKnown = auth.zcodeToken == nil
        var email = auth.email
        for plan in plans {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(in: plan, provider: .zai, endpoint: "Z.ai subscription")
            if let status = plan["status"] as? String, let warning = ResponseSchemaWatch.confirmedEnum(status, provider: .zai, endpoint: "Z.ai subscription", field: "status") { warnings.append(warning) }
            guard let product = plan["productId"] as? String else { details.append(QuotaDiscovery.notice("zai.subscription")); continue }
            let isCoding = product.lowercased().contains("coding") || (plan["productName"] as? String)?.lowercased().contains("coding") == true
            guard isCoding, plan["status"] as? String == "VALID", plan["inCurrentPeriod"] as? Bool == true else { continue }
            let name = (plan["productName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Coding Plan"
            activeCodingPlans.append(name)
            activePlans.append(name)
            if plan["nextRenewTime"] != nil, !(plan["nextRenewTime"] is NSNull), Self.date(plan["nextRenewTime"]) == nil { details.append(QuotaDiscovery.notice("zai.subscription.date")) }
            if let date = Self.date(plan["nextRenewTime"]) {
                let renews = (plan["autoRenew"] as? Bool == true) || QuotaDiscovery.number(plan["autoRenew"]) == 1
                details.append(ProviderUsageDetail(id: "zai.plan." + ZAIAuthStore.hash(product) + ".date", title: name + (renews ? " renews" : " expires"), value: date.formatted(date: .abbreviated, time: .shortened), targetDate: date))
            }
        }
        if let quota, let data = (try? envelope(quota))?["data"] as? [String: Any], let limits = data["limits"] as? [[String: Any]] {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(in: data, provider: .zai, endpoint: "Z.ai quota")
            for limit in limits {
                warnings += ResponseSchemaWatch.confirmedJSONKeys(in: limit, provider: .zai, endpoint: "Z.ai limit")
                guard let type = limit["type"] as? String else { details.append(QuotaDiscovery.notice("zai.limit")); continue }
                if let warning = ResponseSchemaWatch.confirmedEnum(type, provider: .zai, endpoint: "Z.ai limit", field: "type") { warnings.append(warning) }
                let unit = QuotaDiscovery.number(limit["unit"]), number = QuotaDiscovery.number(limit["number"])
                let suffix = type + "." + String(unit ?? -1) + "." + String(number ?? -1)
                var kind: QuotaKind
                if ["TOKENS_LIMIT", "CREDIT_LIMIT"].contains(type), unit == 3, number == 5 { kind = .session }
                else if ["TOKENS_LIMIT", "CREDIT_LIMIT"].contains(type), unit == 6, number == 1 { kind = .weekly }
                else if ["TOKENS_LIMIT", "CREDIT_LIMIT"].contains(type), unit == 4, number == 1 { kind = .daily }
                else if type == "TIME_LIMIT" { kind = .additional(id: "zai.tools", title: "Tools") }
                else { kind = .additional(id: "zai." + suffix, title: QuotaDiscovery.name(type)) }
                if windows.contains(where: { $0.kind == kind }) { kind = .additional(id: "zai." + suffix, title: kind.title) }
                let total = QuotaDiscovery.number(limit["usage"]), used = QuotaDiscovery.number(limit["currentValue"])
                let reportedPercent = QuotaDiscovery.number(limit["percentage"])
                let percent = reportedPercent ?? ((total ?? 0) > 0 && used != nil ? used! / total! * 100 : nil)
                if let percent, (0...100).contains(percent) {
                    let validCounts = total != nil && total! > 0 && used != nil && (0...total!).contains(used!)
                    windows.append(QuotaWindow(kind: kind, usedPercent: percent, resetsAt: Self.date(limit["nextResetTime"]), remainingCount: validCounts ? total! - used! : nil, limitCount: validCounts ? total : nil))
                } else if let remaining = QuotaDiscovery.number(limit["remaining"]), remaining >= 0 {
                    details.append(ProviderUsageDetail(id: "zai." + suffix + ".remaining", title: QuotaDiscovery.name(type), value: QuotaWindow.formatCount(remaining) + " left"))
                } else { details.append(QuotaDiscovery.notice("zai." + suffix)) }
                for entry in limit["usageDetails"] as? [[String: Any]] ?? [] {
                    warnings += ResponseSchemaWatch.confirmedJSONKeys(in: entry, provider: .zai, endpoint: "Z.ai usage detail")
                    if let model = entry["modelCode"] as? String, let value = QuotaDiscovery.number(entry["usage"]), value >= 0 {
                        details.append(ProviderUsageDetail(id: "zai." + suffix + ".model." + ZAIAuthStore.hash(model), title: (entry["displayName"] as? String) ?? QuotaDiscovery.name(model), value: QuotaWindow.formatCount(value) + " used"))
                    } else { details.append(QuotaDiscovery.notice("zai.model")) }
                }
            }
        } else if !activeCodingPlans.isEmpty {
            details.append(ProviderUsageDetail(id: "compatibility.zai.quota", title: "Coding Plan quota", value: "Unavailable"))
        }
        var startWindows: [QuotaWindow] = []
        if auth.zcodeToken != nil {
            if let start, let data = (try? envelope(start))?["data"] as? [String: Any],
               let startPlans = data["plans"] as? [[String: Any]], let balances = data["balances"] as? [[String: Any]] {
                startKnown = true
                warnings += ResponseSchemaWatch.confirmedJSONKeys(in: data, provider: .zai, endpoint: "ZCode balance")
                warnings += ResponseSchemaWatch.httpHeaders(start, provider: .zai, endpoint: "ZCode balance")
                var periods: [String: String] = [:]
                for plan in startPlans {
                    warnings += ResponseSchemaWatch.confirmedJSONKeys(in: plan, provider: .zai, endpoint: "ZCode plan")
                    if let status = plan["status"] as? String, let warning = ResponseSchemaWatch.confirmedEnum(status, provider: .zai, endpoint: "ZCode plan", field: "status") { warnings.append(warning) }
                    guard plan["status"] as? String == "active", let planID = plan["plan_id"] as? String else { continue }
                    let title = (plan["name"] as? String) ?? "Start Plan"
                    activePlans.append(title)
                    if let expiry = Self.date(plan["ends_at"]) {
                        details.append(ProviderUsageDetail(id: "zai.start." + ZAIAuthStore.hash(planID) + ".plan-expiry", title: title + " expires", value: expiry.formatted(date: .abbreviated, time: .shortened), targetDate: expiry))
                    }
                    for entitlement in plan["entitlements"] as? [[String: Any]] ?? [] {
                        warnings += ResponseSchemaWatch.confirmedJSONKeys(in: entitlement, provider: .zai, endpoint: "ZCode entitlement")
                        guard let id = entitlement["entitlement_id"] as? String else { details.append(QuotaDiscovery.notice("zai.start.entitlement")); continue }
                        let key = planID + "\0" + id
                        if let period = entitlement["period"] as? String {
                            periods[key] = period
                            if let warning = ResponseSchemaWatch.confirmedEnum(period, provider: .zai, endpoint: "ZCode entitlement", field: "period") { warnings.append(warning) }
                        }
                        if let effective = Self.date(entitlement["effective_at"]), effective > now {
                            details.append(ProviderUsageDetail(id: "zai.start." + ZAIAuthStore.hash(key) + ".effective", title: ((entitlement["show_name"] as? String) ?? "Allowance") + " available", value: effective.formatted(date: .abbreviated, time: .shortened), targetDate: effective))
                        }
                        if !balances.contains(where: { $0["plan_id"] as? String == planID && $0["entitlement_id"] as? String == id }),
                           let grant = QuotaDiscovery.number(entitlement["grant_units"]), grant >= 0 {
                            details.append(ProviderUsageDetail(id: "zai.start." + ZAIAuthStore.hash(key) + ".grant", title: (entitlement["show_name"] as? String) ?? "Allowance", value: QuotaWindow.formatCount(grant) + " " + ((entitlement["unit_type"] as? String) ?? "units") + " per " + ((entitlement["period"] as? String) ?? "period")))
                        }
                    }
                }
                for row in balances {
                    warnings += ResponseSchemaWatch.confirmedJSONKeys(in: row, provider: .zai, endpoint: "ZCode bucket")
                    guard let planID = row["plan_id"] as? String, let entitlementID = row["entitlement_id"] as? String,
                          let remaining = QuotaDiscovery.number(row["remaining_units"]), remaining >= 0 else { details.append(QuotaDiscovery.notice("zai.start.bucket")); continue }
                    let title = (row["show_name"] as? String) ?? "Start Plan"
                    let total = QuotaDiscovery.number(row["total_units"]), unit = (row["unit_type"] as? String) ?? "units"
                    let period = periods[planID + "\0" + entitlementID]
                    var identifier = "zai.start." + ZAIAuthStore.hash(planID + "\0" + entitlementID + "\0" + unit)
                    if startWindows.contains(where: { $0.kind.rawValue == "additional:" + identifier }) {
                        guard let bucket = row["bucket_id"] as? String else { details.append(QuotaDiscovery.notice("zai.start.duplicate")); continue }
                        identifier += "." + ZAIAuthStore.hash(bucket)
                    }
                    let reset = ["daily", "weekly", "monthly"].contains(period ?? "") ? Self.date(row["period_end"])?.addingTimeInterval(1) : nil
                    if let total, total > 0, remaining <= total {
                        startWindows.append(QuotaWindow(kind: .additional(id: identifier, title: title + " " + (unit == "token" ? "tokens" : QuotaDiscovery.name(unit))), usedPercent: (total - remaining) / total * 100,
                            resetsAt: reset, remainingCount: remaining, limitCount: total))
                    } else {
                        details.append(ProviderUsageDetail(id: identifier + ".remaining", title: title, value: QuotaWindow.formatCount(remaining) + " " + unit + " left"))
                    }
                    if reset == nil, let expiry = Self.date(row["expires_at"]) {
                        details.append(ProviderUsageDetail(id: identifier + ".expiry", title: title + " expires", value: expiry.formatted(date: .abbreviated, time: .shortened), targetDate: expiry))
                    }
                    if let available = QuotaDiscovery.number(row["available_units"]), available >= 0, available != remaining {
                        details.append(ProviderUsageDetail(id: identifier + ".available", title: title + " available now", value: QuotaWindow.formatCount(available) + " " + unit))
                    }
                }
            } else { details.append(ProviderUsageDetail(id: "compatibility.zai.start", title: "Start Plan", value: "Unavailable")) }
        }
        if windows.isEmpty, startWindows.isEmpty || !activeCodingPlans.isEmpty {
            windows = [QuotaWindow(kind: .additional(id: "zai.coding", title: "Coding Plan"), usedPercent: 0, resetsAt: nil, isInactive: true, inactiveDetail: activeCodingPlans.isEmpty ? "No plan" : "Unavailable")]
        }
        if !startWindows.isEmpty { windows = startWindows + windows }
        if let account, let profile = (try? envelope(account))?["data"] as? [String: Any] {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(in: profile, provider: .zai, endpoint: "Z.ai account")
            email = email ?? ZAIAuthStore.unmaskedEmail(profile["email"])
            for (key, title) in [("balance", "API balance"), ("availableBalance", "API available balance"), ("giveAmount", "API gift balance"), ("rechargeAmount", "API purchased balance")] {
                if let amount = QuotaDiscovery.number(profile[key]), amount >= 0 {
                    details.append(ProviderUsageDetail(id: "zai.account." + key, title: title, value: QuotaWindow.formatCount(amount) + " (unit unconfirmed)"))
                }
            }
        }
        return ProviderSnapshot(provider: .zai, planName: activePlans.isEmpty ? (startKnown ? "Free" : nil) : activePlans.joined(separator: " · "), windows: windows, fetchedAt: now,
            credentialSource: auth.source, accountLabel: "zai-session:" + ZAIAuthStore.hash(auth.source + "\0" + (email ?? auth.token)), accountEmail: email,
            usageDetails: details, diagnosticWarnings: warnings)
    }
}
