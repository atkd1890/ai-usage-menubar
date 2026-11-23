import Foundation

actor BuddyProvider: UsageProvider {
    nonisolated let id = ProviderID.buddy
    private let http: any HTTPClient
    private let identity: AccountIdentityCache?
    private let method: @Sendable () -> ProviderLoginMethod
    private let credential: @Sendable (ProviderLoginMethod) throws -> BuddyCredential
    init(http: (any HTTPClient)? = nil,
         method: @escaping @Sendable () -> ProviderLoginMethod = { .selected(for: .buddy) },
         credential: @escaping @Sendable (ProviderLoginMethod) throws -> BuddyCredential = { try BuddyAuthStore().load($0) }) {
        self.http = http ?? GeminiReadOnlyHTTPClient(allowedHosts: ["www.codebuddy.ai"])
        self.method = method; self.credential = credential
        self.identity = http == nil ? AccountIdentityCache(provider: .buddy, source: "selected") : nil
    }
    func fetch() async throws -> ProviderSnapshot {
        let auth = try credential(method())
        guard auth.host == "www.codebuddy.ai" else { throw ProviderFailure(.storage, "Unsupported Buddy account region.") }
        func request(_ path: String, body: [String: Any]? = nil) throws -> HTTPRequest {
            var headers = auth.headers
            headers["Accept"] = "application/json"; headers["Content-Type"] = "application/json"
            headers["X-Client-Platform"] = "web"
            return HTTPRequest(method: body == nil ? .get : .post, url: URL(string: "https://" + auth.host + path)!, headers: headers,
                body: try body.map { try JSONSerialization.data(withJSONObject: $0) })
        }
        let accounts = try Self.body(await http.send(request("/console/accounts")))
        guard let rows = accounts["accounts"] as? [[String: Any]] else { throw ProviderFailure(.invalidResponse, "Buddy account response changed.") }
        let selected: [String: Any]?
        if let uid = auth.accountID { selected = rows.first { $0["uid"] as? String == uid && $0["type"] as? String == "personal" } }
        else {
            let current = rows.filter { $0["lastLogin"] as? Bool == true && $0["type"] as? String == "personal" }
            selected = current.count == 1 ? current[0] : (rows.count == 1 && rows[0]["type"] as? String == "personal" ? rows[0] : nil)
        }
        guard let selected, let uid = selected["uid"] as? String else {
            throw ProviderFailure(.authentication, "Select one personal Buddy account in the chosen login source. Enterprise pools are not yet supported.")
        }
        let summary = try await http.send(request("/billing/meter/get-user-resource-summary", body: [:]))
        let data = try Self.body(summary)
        guard let packages = data["Packages"] as? [[String: Any]] else { throw ProviderFailure(.invalidResponse, "Buddy credit summary changed.") }
        let codes = Array(Set(packages.compactMap { $0["PackageCode"] as? String })).sorted()
        var pageRows: [String: [[String: Any]]] = [:], partial: [String] = []
        if !codes.isEmpty {
            let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
            let day = formatter.string(from: Date())
            for family in ["free", "paid"] {
                do {
                    var all: [[String: Any]] = []; var seen = Set<String>()
                    for page in 1...100 {
                        let payload: [String: Any] = ["PageNumber": page, "PageSize": 100, "Status": [0,3], "PackageCodes": codes,
                            "SlicePeriodStartTime": day + " 00:00:00", "SlicePeriodEndTime": day + " 23:59:59", "NeedRenewInfo": true]
                        let body = try Self.body(await http.send(request("/billing/meter/get-user-resource-" + family + "-packages", body: payload)))
                        guard let entries = body["Accounts"] as? [[String: Any]], let count = QuotaDiscovery.number(body["TotalCount"]), count >= 0 else {
                            throw ProviderFailure(.invalidResponse, "Buddy package response changed.")
                        }
                        let pageIDs = entries.compactMap { $0["ResourceId"] as? String }
                        guard Set(pageIDs).isDisjoint(with: seen), entries.count <= 100 else { throw ProviderFailure(.invalidResponse, "Buddy package pagination changed.") }
                        seen.formUnion(pageIDs); all += entries
                        if all.count >= Int(count) { break }
                        guard !entries.isEmpty, page < 100 else { throw ProviderFailure(.invalidResponse, "Buddy packages are incomplete.") }
                    }
                    pageRows[family] = all
                } catch { partial.append(family) }
            }
        }
        let email = await identity?.read(credential: auth.source + "\0" + auth.fingerprint) { [http] in
            let response = try await http.send(HTTPRequest(method: .get,
                url: URL(string: "https://www.codebuddy.ai/auth/realms/copilot/protocol/openid-connect/userinfo")!, headers: auth.headers, body: nil))
            guard response.statusCode == 200, let profile = try? ProviderParsing.object(from: response.body), profile["email_verified"] as? Bool == true else { return nil }
            return AccountEmail.validated(profile["email"])
        }
        return try Self.map(summary: summary, packages: pageRows, partial: partial, source: auth.source,
            accountID: uid, email: AccountEmail.validated(selected["email"]) ?? email)
    }
    static func body(_ response: HTTPResponse) throws -> [String: Any] {
        if [401,403].contains(response.statusCode) { throw ProviderFailure(.authentication, "Buddy rejected the selected session. Sign in to that source again.") }
        if response.statusCode == 429 { throw ProviderFailure(.rateLimited, "Buddy usage is rate limited.") }
        guard response.statusCode == 200, response.body.count < 4_000_000,
              let root = try? ProviderParsing.object(from: response.body), QuotaDiscovery.number(root["code"]) == 0,
              let data = root["data"] as? [String: Any] else { throw ProviderFailure(.invalidResponse, "Buddy usage response changed.") }
        return data
    }
    static func date(_ value: Any?) -> Date? {
        if let number = QuotaDiscovery.number(value), number <= 0 { return nil }
        if let text = value as? String {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let date = formatter.date(from: text) { return date }
        }
        return ProviderParsing.date(value)
    }
    static let baseCodes: Set<String> = ["TCACA_code_001_PqouKr6QWV", "TCACA_code_035_ArVxJcGDsm", "TCACA_code_008_cfWoLwvjU4", "TCACA_code_002_AkiJS3ZHF5", "TCACA_code_003_FAnt7lcmRT", "TCACA_code_039_KRcQj7wUat", "TCACA_code_040_mi9rCYg46x"]
    static let addOnCodes: Set<String> = ["TCACA_code_009_0XmEQc2xOf", "TCACA_code_036_lupO5WgNdG"]
    static func map(summary: HTTPResponse, packages: [String: [[String: Any]]], partial: [String] = [], source: String,
                    accountID: String, email: String? = nil, now: Date = Date()) throws -> ProviderSnapshot {
        let data = try body(summary)
        guard let summaries = data["Packages"] as? [[String: Any]] else { throw ProviderFailure(.invalidResponse, "Buddy credit summary changed.") }
        var warnings = ResponseSchemaWatch.confirmedJSONKeys(in: data, provider: .buddy, endpoint: "Buddy summary")
        warnings += ResponseSchemaWatch.httpHeaders(summary, provider: .buddy, endpoint: "Buddy summary")
        var windows: [QuotaWindow] = [], details: [ProviderUsageDetail] = []
        let entries = packages.values.flatMap { $0 }
        var seen = Set<String>()
        for row in summaries {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(in: row, provider: .buddy, endpoint: "Buddy summary package")
            guard let code = row["PackageCode"] as? String, seen.insert(code).inserted else { details.append(QuotaDiscovery.notice("buddy.summary")); continue }
            let isBase = baseCodes.contains(code)
            let isGift = ["TCACA_code_006_DbXS0lrypC", "TCACA_code_007_nzdH5h4Nl0", "TCACA_code_037_WxOD3MpI2o"].contains(code)
            let title = isBase ? "Credits" : (addOnCodes.contains(code) ? "Add-on" : (isGift ? "Gift credits" : "Additional credits"))
            let related = entries.filter { $0["PackageCode"] as? String == code }
            for entry in related { warnings += ResponseSchemaWatch.confirmedJSONKeys(in: entry, provider: .buddy, endpoint: "Buddy package") }
            let total = QuotaDiscovery.number(row["CycleTotalCapacity"]), left = QuotaDiscovery.number(row["CycleRemainCapacity"])
            guard let left, left >= 0 else { details.append(QuotaDiscovery.notice("buddy." + code)); continue }
            let identifier = "buddy." + ZAIAuthStore.hash(code)
            var hasReset = false
            if baseCodes.contains(code), let total, total > 0, left <= total {
                let cycles = related.filter { QuotaDiscovery.number($0["CapacityType"]) == 4 }
                let reset = cycles.compactMap { entry -> Date? in
                    guard let end = date(entry["CycleEndTime"]), let expiry = date(entry["DeductionEndTime"]), end < expiry else { return nil }
                    return end.addingTimeInterval(1)
                }.min()
                hasReset = reset != nil
                let monthly = cycles.contains { entry in
                    guard let start = date(entry["CycleStartTime"]), let end = date(entry["CycleEndTime"]) else { return false }
                    return (27 * 86400...32 * 86400).contains(end.timeIntervalSince(start))
                }
                let kind: QuotaKind = monthly && !windows.contains(where: { $0.kind == .monthly }) ? .monthly : .additional(id: identifier, title: monthly ? "Monthly" : title)
                windows.append(QuotaWindow(kind: kind, usedPercent: (total - left) / total * 100, resetsAt: reset, remainingCount: left, limitCount: total))
            } else {
                let progress = total != nil && total! > 0 && left <= total! ? BoundedCreditProgress(label: title, used: total! - left, limit: total!, resetNote: nil) : nil
                details.append(ProviderUsageDetail(id: identifier + ".credits", title: title, value: QuotaWindow.formatCount(left) + " credits left", boundedProgress: progress))
            }
            for (index, entry) in related.enumerated() {
                let resource = (entry["ResourceId"] as? String).map(ZAIAuthStore.hash) ?? String(index)
                if (!isBase || !hasReset), let expiry = date(entry["DeductionEndTime"] ?? entry["ExpiredTime"] ?? entry["PackageEndTime"]) {
                    details.append(ProviderUsageDetail(id: identifier + "." + resource + ".expiry", title: title + " expires", value: expiry.formatted(date: .abbreviated, time: .shortened), targetDate: expiry))
                }
                // Package counts are the breakdown of the summary, never another added allowance.
                if related.count > 1, let amount = QuotaDiscovery.number(entry["CapacityRemainPrecise"] ?? entry["CycleCapacityRemainPrecise"]), amount >= 0 {
                    details.append(ProviderUsageDetail(id: identifier + "." + resource + ".left", title: title + " package", value: QuotaWindow.formatCount(amount) + " credits left"))
                }
            }
            if let frozen = QuotaDiscovery.number(row["CycleFrozenCapacity"]), frozen > 0 {
                details.append(ProviderUsageDetail(id: identifier + ".frozen", title: title + " reserved", value: QuotaWindow.formatCount(frozen) + " credits"))
            }
        }
        if windows.isEmpty { windows.append(QuotaWindow(kind: .additional(id: "buddy.credits", title: "Credits"), usedPercent: 0, resetsAt: nil, isInactive: true, inactiveDetail: summaries.isEmpty ? "No allocation" : "Unavailable")) }
        for family in partial { details.append(ProviderUsageDetail(id: "compatibility.buddy." + family, title: "Credit package details", value: family.capitalized + " packages unavailable")) }
        // CreditGroups and TotalCredits overlap Packages; retain new group structures as compatibility notices until reviewed.
        if let groups = data["CreditGroups"] as? [[String: Any]] {
            for group in groups {
                warnings += ResponseSchemaWatch.confirmedJSONKeys(in: group, provider: .buddy, endpoint: "Buddy credit group")
                if let kind = group["Kind"] as? String, !["plan_base", "plan_bonus", "addon", "benefit"].contains(kind) { details.append(QuotaDiscovery.notice("buddy.credit-group")) }
            }
        }
        let plan = (data["SubscriptionPackageName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (data["IsPaidUser"] as? Bool == false ? "Free" : nil)
        return ProviderSnapshot(provider: .buddy, planName: plan, windows: windows, fetchedAt: now, credentialSource: source,
            accountLabel: "buddy-session:" + ZAIAuthStore.hash(source + "\0" + accountID), accountEmail: email, usageDetails: details, diagnosticWarnings: warnings)
    }
}
