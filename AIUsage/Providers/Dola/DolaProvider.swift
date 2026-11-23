import CryptoKit
import Foundation

/// Consumer Dola quota only. Deliberately excludes Lark Suite credentials.
actor DolaProvider: UsageProvider {
    nonisolated let id = ProviderID.dola
    static let cookieNames = ["sessionid", "sessionid_ss", "passport_csrf_token"]
    static let paths = [
        "overview": "/alice/commerce/sale/subscription/overview/",
        "status": "/alice/commerce/sale/subscription/status/",
        "usage": "/alice/commerce/sale/entitlement/usage_detail/",
        "ogf": "/alice/user/get_user_ogf_quota"
    ]
    private let identity: AccountIdentityCache?
    private let http: any HTTPClient
    private let method: @Sendable () -> ProviderLoginMethod
    private let cookies: @Sendable (WebSessionSource) throws -> String

    init(http: (any HTTPClient)? = nil,
         method: @escaping @Sendable () -> ProviderLoginMethod = { .selected(for: .dola) },
         sessions: WebSessionStore = WebSessionStore(),
         identity: AccountIdentityCache? = nil,
         cookies: (@Sendable (WebSessionSource) throws -> String)? = nil) {
        self.http = http ?? GeminiReadOnlyHTTPClient(allowedHosts: ["www.dola.com"]); self.method = method
        self.identity = identity ?? (http == nil ? AccountIdentityCache(provider: .dola, source: "selected") : nil)
        self.cookies = cookies ?? { try sessions.cookies(source: $0, domain: "dola.com", names: Self.cookieNames) }
    }

    static func source(for method: ProviderLoginMethod) throws -> (WebSessionSource, String) {
        switch method {
        case .edge: return (.edge, "Edge Default")
        case .chrome: return (.chrome, "Chrome Default")
        case .desktop: return (.dolaDesktop, "Dola desktop")
        default: throw ProviderFailure(.storage, "Unsupported Dola login method.")
        }
    }

    func fetch() async throws -> ProviderSnapshot {
        let selected = method()
        let (source, label) = try Self.source(for: selected)
        let cookie: String
        do { cookie = try cookies(source) }
        catch let failure as ProviderFailure where failure.kind == .storage {
            if failure.message.localizedCaseInsensitiveContains("macOS denied access") ||
                failure.message.localizedCaseInsensitiveContains("Privacy & Security") {
                throw failure
            }
            throw ProviderFailure(.storage, "Dola login in \(label) could not be read or decrypted. Check the selected source’s Safe Storage access.")
        }
        guard let seed = cookie.components(separatedBy: "; ").first(where: {
            ($0.hasPrefix("sessionid=") || $0.hasPrefix("sessionid_ss=")) && !$0.hasSuffix("=")
        }) else { throw ProviderFailure(.authentication, "Sign in to Dola in the selected source.") }
        let aid = selected == .desktop ? "582465" : "495671"
        func request(_ key: String) -> HTTPRequest {
            HTTPRequest(method: .post, url: URL(string: "https://www.dola.com" + Self.paths[key]! +
                "?aid=\(aid)&device_platform=web&web_platform=browser&use-olympus-account=1")!,
                headers: ["Cookie": cookie, "Content-Type": "application/json", "Accept": "application/json",
                          "Origin": "https://www.dola.com", "Referer": "https://www.dola.com/chat/",
                          "use-olympus-account": "1", "aid": aid],
                body: Data(#"{"product_line":"membership"}"#.utf8))
        }
        let overview = try await http.send(request("overview"))
        // Fail closed on the selected login before calling supplementary endpoints.
        _ = try Self.body(overview)
        var supplemental: [String: HTTPResponse] = [:]
        for key in ["status", "usage", "ogf"] {
            supplemental[key] = try? await http.send(request(key))
        }
        let email = await identity?.read(credential: label + "\0" + seed) { [http] in
            let response = try await http.send(HTTPRequest(method: .get,
                url: URL(string: "https://www.dola.com/passport/account/info/v2/?aid=\(aid)&device_platform=web&sdk_version=2.2.11-doubao.0")!,
                headers: ["Cookie": cookie, "Accept": "application/json"], body: nil))
            return Self.profileEmail(response)
        }
        let identitySeed = label + "\0" + (email ?? seed)
        let hash = SHA256.hash(data: Data(identitySeed.utf8)).map { String(format: "%02x", $0) }.joined()
        return try Self.map(overview: overview, supplemental: supplemental,
                            source: label, historyID: "dola-session:" + hash, email: email)
    }

    static func profileEmail(_ response: HTTPResponse) -> String? {
        guard response.statusCode == 200,
              let root = try? ProviderParsing.object(from: response.body),
              root["message"] as? String == "success",
              let data = root["data"] as? [String: Any] else { return nil }
        return AccountEmail.validated(data["email"])
    }

    static func body(_ response: HTTPResponse) throws -> [String: Any] {
        if [401, 403].contains(response.statusCode) {
            throw ProviderFailure(.authentication, "Dola session rejected. Sign in to the selected source.")
        }
        if response.statusCode == 429 { throw ProviderFailure(.rateLimited, "Dola usage is rate limited.") }
        guard response.statusCode == 200, response.body.count <= 2_000_000,
              let root = try? ProviderParsing.object(from: response.body),
              let code = QuotaDiscovery.number(root["code"]) else {
            throw ProviderFailure(.invalidResponse, "Dola usage response changed.")
        }
        if code == 710012001 {
            throw ProviderFailure(.authentication, "Dola session expired. Sign in to the selected source.")
        }
        guard code == 0, let data = root["data"] as? [String: Any] else {
            throw ProviderFailure(.invalidResponse, "Dola usage is unavailable.")
        }
        return data
    }

    static func map(overview: HTTPResponse, supplemental: [String: HTTPResponse] = [:],
                    source: String = "Edge Default", historyID: String, email: String? = nil, now: Date = Date()) throws -> ProviderSnapshot {
        let data = try body(overview)
        var warnings = ResponseSchemaWatch.httpHeaders(overview, provider: .dola, endpoint: "Dola overview")
        func watch(_ object: [String: Any], _ endpoint: String) {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(in: object, provider: .dola, endpoint: endpoint)
            warnings += ResponseSchemaWatch.jsonBodyDeprecation(object, provider: .dola, endpoint: endpoint)
        }
        watch(data, "Dola overview")
        var windows: [QuotaWindow] = []
        var details: [ProviderUsageDetail] = []
        guard let member = data["member_info"] as? [String: Any], !member.isEmpty else {
            throw ProviderFailure(.invalidResponse, "Dola membership response changed.")
        }
        watch(member, "Dola member")
        let active = member["hasActiveSubscription"] as? Bool
        if active == false {
            windows.append(QuotaWindow(kind: .additional(id: "dola.usage", title: "Usage"),
                usedPercent: 0, resetsAt: nil, isInactive: true, inactiveDetail: "No plan"))
        }
        for (key, title) in [("has_business_subscription", "Business plan"),
                             ("has_team_subscription", "Team plan"),
                             ("hasEnterpriseSubscription", "Enterprise plan")] {
            if member[key] as? Bool == true {
                details.append(ProviderUsageDetail(id: "dola." + key, title: title, value: "Active"))
            }
        }
        // Do not guess the schema or capacity of paid entitlements from empty free-plan arrays.
        let collections = ["entitlements", "package_entitlement_groups", "quota_package_entitlement_groups",
                           "enterprise_package_entitlement_groups", "incentive_quota_entitlements"]
        for key in collections where (data[key] as? [Any])?.isEmpty == false {
            details.append(QuotaDiscovery.notice("dola." + key))
        }
        for key in ["window_limit_section", "enterprise_window_limit_section"] {
            if let section = data[key] as? [String: Any] {
                watch(section, "Dola window section")
                if (section["window_limit_groups"] as? [Any])?.isEmpty == false {
                    details.append(QuotaDiscovery.notice("dola." + key))
                }
                if let count = QuotaDiscovery.number(section["entitlement_count"]), count >= 0,
                   count > 0 || member["hasEnterpriseSubscription"] as? Bool == true {
                    details.append(ProviderUsageDetail(id: "dola." + key + ".count", title: "Enterprise entitlements",
                                                      value: QuotaWindow.formatCount(count)))
                }
                if let exhausted = section["usage_exhausted"] as? Bool,
                   member["hasEnterpriseSubscription"] as? Bool == true {
                    details.append(ProviderUsageDetail(id: "dola." + key + ".exhausted", title: "Enterprise quota exhausted",
                                                      value: exhausted ? "Yes" : "No"))
                }
            }
        }
        for key in ["status", "usage", "ogf"] {
            guard let response = supplemental[key], let value = try? body(response) else {
                details.append(ProviderUsageDetail(id: "compatibility.dola." + key,
                    title: "Partial Dola data", value: "\(QuotaDiscovery.name(key)) unavailable"))
                continue
            }
            warnings += ResponseSchemaWatch.httpHeaders(response, provider: .dola, endpoint: "Dola " + key)
            watch(value, "Dola " + key)
            if key == "status" {
                if value["is_subscribing"] as? Bool == true {
                    details.append(ProviderUsageDetail(id: "dola.is_subscribing", title: "Subscription", value: "Pending"))
                }
            } else if key == "usage" {
                if active != false, let percent = QuotaDiscovery.number(value["total_used_percent"]), (0...100).contains(percent) {
                    windows.insert(QuotaWindow(kind: .additional(id: "dola.usage", title: "Usage"),
                        usedPercent: percent, resetsAt: nil), at: 0)
                }
                if (value["window_limit_groups"] as? [Any])?.isEmpty == false {
                    details.append(QuotaDiscovery.notice("dola.usage.windows"))
                }
            } else {
                let left = QuotaDiscovery.number(value["quota_left"]), total = QuotaDiscovery.number(value["total_quota"])
                if let left, let total, total > 0, (0...total).contains(left) {
                    windows.append(QuotaWindow(kind: .additional(id: "dola.ogf", title: "OGF quota"),
                        usedPercent: (total - left) / total * 100, resetsAt: nil,
                        remainingCount: left, limitCount: total))
                } else if let left, left >= 0, total == nil || total! > 0 || left > 0 {
                    let count = QuotaWindow.formatCount(left)
                    let validTotal = total.flatMap { $0 >= 0 ? $0 : nil }
                    details.append(ProviderUsageDetail(id: "dola.ogf", title: "OGF quota",
                        value: validTotal.map { count + " / " + QuotaWindow.formatCount($0) + " left" } ?? count + " left"))
                } else if let total, total > 0 {
                    details.append(ProviderUsageDetail(id: "dola.ogf", title: "OGF quota", value: QuotaWindow.formatCount(total) + " total"))
                }
            }
        }
        let sub = data["current_subscription"] as? [String: Any] ?? [:]
        watch(sub, "Dola subscription")
        let display = sub["display"] as? [String: Any] ?? [:]
        watch(display, "Dola subscription display")
        // Zero timestamps are absent, not 1970 dates; period/cadence is not guessed.
        for (key, title) in [("end_time", "Subscription ends"), ("next_deduct_time", "Next billing")] {
            if let raw = QuotaDiscovery.number(sub[key]), raw > 0, let date = ProviderParsing.date(sub[key]) {
                details.append(ProviderUsageDetail(id: "dola." + key, title: title,
                    value: date.formatted(date: .abbreviated, time: .shortened), targetDate: date))
            }
        }
        guard !windows.isEmpty || !details.isEmpty else {
            throw ProviderFailure(.invalidResponse, "Dola returned no supported account usage.")
        }
        return ProviderSnapshot(provider: .dola,
            planName: active == false ? "Free" : (display["product_name"] as? String).map(QuotaDiscovery.title),
            windows: windows, fetchedAt: now, credentialSource: source, accountLabel: historyID, accountEmail: AccountEmail.validated(email),
            usageDetails: details, diagnosticWarnings: ResponseSchemaWatch.deduplicated(warnings))
    }
}
