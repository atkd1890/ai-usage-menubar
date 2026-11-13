import Foundation
import CoreFoundation
import CryptoKit

/// Only the two credential paths and read-only endpoints verified with the user's sessions.
actor ConsumerQuotaProvider: UsageProvider {
    nonisolated let id: ProviderID
    private let http: any HTTPClient
    private let sessions: WebSessionStore
    private let nativeKimi: @Sendable () throws -> KimiNativeSession
    private let allowRefresh: @Sendable () -> Bool
    private var kimiCache: (fingerprint: Data, session: KimiNativeSession)?
    private var refreshTask: (fingerprint: Data, task: Task<KimiNativeSession, Error>)?

    init(id: ProviderID, http: (any HTTPClient)? = nil, sessions: WebSessionStore = WebSessionStore(),
         nativeKimi: @escaping @Sendable () throws -> KimiNativeSession = { try KimiNativeSession.load() },
         allowRefresh: @escaping @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: "kimiNativeRefreshAllowed.v1") }) {
        self.id = id; self.sessions = sessions
        self.nativeKimi = nativeKimi; self.allowRefresh = allowRefresh
        self.http = http ?? GeminiReadOnlyHTTPClient(allowedHosts: [id == .manus ? "api.manus.im" : "www.kimi.ai"])
    }
    func fetch() async throws -> ProviderSnapshot {
        let token: String
        if id == .manus {
            let cookie = try sessions.cookies(source: .edge, domain: "manus.im", names: ["session_id"])
            guard cookie.hasPrefix("session_id=") else { throw ProviderFailure(.authentication, "Sign in to Manus in Edge Default.") }
            token = String(cookie.dropFirst("session_id=".count))
            return try Self.manus(await request("https://api.manus.im/user.v1.UserService/GetAvailableCredits", token: token))
        }
        guard id == .kimi else { throw ProviderFailure(.invalidResponse, "Unsupported consumer provider.") }
        let load = nativeKimi
        let native = try await Task.detached(priority: .utility) { try load() }.value
        let fingerprint = Data(SHA256.hash(data: Data((native.access + "\0" + (native.refresh ?? "")).utf8)))
        var session = kimiCache?.fingerprint == fingerprint ? kimiCache!.session : native
        for attempt in 0...1 {
            let subscription = try await request("https://www.kimi.ai/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscription", token: session.access)
            if subscription.statusCode == 401 && attempt == 0 {
                session = try await refreshed(session, fingerprint: fingerprint); continue
            }
            _ = try Self.body(subscription)
            let stats = try await request("https://www.kimi.ai/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats", token: session.access)
            if stats.statusCode == 401 && attempt == 0 {
                session = try await refreshed(session, fingerprint: fingerprint); continue
            }
            let code = try? await request("https://www.kimi.ai/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages", token: session.access,
                payload: Data(#"{"scope":["FEATURE_CODING"]}"#.utf8))
            return try Self.kimi(subscription: subscription, stats: stats, code: code ?? HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        }
        throw ProviderFailure(.authentication, "Kimi session expired. Sign in to Kimi desktop again.")
    }
    private func refreshed(_ session: KimiNativeSession, fingerprint: Data) async throws -> KimiNativeSession {
        guard allowRefresh(), let refresh = session.refresh, KimiNativeSession.valid(refresh) else {
            throw ProviderFailure(.authentication, "Kimi session expired. Open Kimi desktop to renew the login.")
        }
        if let active = refreshTask, active.fingerprint == fingerprint { return try await active.task.value }
        let http = self.http
        let task = Task<KimiNativeSession, Error> {
            let response = try await http.send(HTTPRequest(method: .get,
                url: URL(string: "https://www.kimi.ai/api/auth/token/refresh")!, headers: [
                    "Authorization": "Bearer " + refresh, "Accept": "application/json",
                    "Origin": "https://www.kimi.ai", "User-Agent": "Mozilla/5.0"
                ], body: nil))
            let body = try Self.body(response)
            guard let access = (body["access_token"] ?? body["accessToken"]) as? String, KimiNativeSession.valid(access) else {
                throw ProviderFailure(.invalidResponse, "Kimi refresh returned no valid access token.")
            }
            let next = (body["refresh_token"] ?? body["refreshToken"]) as? String ?? refresh
            guard KimiNativeSession.valid(next) else { throw ProviderFailure(.invalidResponse, "Kimi refresh returned an invalid session.") }
            return KimiNativeSession(access: access, refresh: next)
        }
        refreshTask = (fingerprint, task)
        defer { if refreshTask?.fingerprint == fingerprint { refreshTask = nil } }
        let updated = try await task.value
        kimiCache = (fingerprint, updated) // RAM only; native storage is never modified.
        return updated
    }
    private func request(_ endpoint: String, token: String, payload: Data = Data("{}".utf8)) async throws -> HTTPResponse {
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0 == ";" }) else {
            throw ProviderFailure(.authentication, "Invalid selected session.")
        }
        var headers = [
            "Authorization": "Bearer " + token, "Content-Type": "application/json", "Accept": "application/json",
            "User-Agent": "Mozilla/5.0"
        ]
        if id == .kimi {
            headers["Origin"] = "https://www.kimi.ai"
            headers["Referer"] = "https://www.kimi.ai/code/console"
            headers["Cookie"] = "kimi-auth=" + token
        }
        return try await http.send(HTTPRequest(method: .post, url: URL(string: endpoint)!, headers: headers, body: payload))
    }
    private static func body(_ response: HTTPResponse) throws -> [String: Any] {
        guard response.statusCode == 200 else {
            throw ProviderFailure([401, 403].contains(response.statusCode) ? .authentication : response.statusCode == 429 ? .rateLimited : .transient,
                                  "Usage request returned HTTP \(response.statusCode). Refresh the selected login if rejected.")
        }
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw ProviderFailure(.invalidResponse, "Usage response format changed.")
        }
        return object
    }
    private static func number(_ value: Any?) -> Double? {
        let n: Double?
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        if let s = value as? String { n = Double(s) } else { n = (value as? NSNumber)?.doubleValue }
        return n.flatMap { $0.isFinite ? $0 : nil }
    }
    private static func date(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
    static func manus(_ response: HTTPResponse) throws -> ProviderSnapshot {
        let root = try body(response)
        let data = (root["data"] ?? root["result"] ?? root["response"] ?? root["availableCredits"]) as? [String: Any] ?? root
        var windows: [QuotaWindow] = []
        if let maximum = number(data["maxRefreshCredits"]), maximum > 0,
           let remaining = number(data["refreshCredits"]), (0...maximum).contains(remaining) {
            windows.append(QuotaWindow(kind: .daily, usedPercent: (maximum - remaining) / maximum * 100,
                resetsAt: date(data["nextRefreshTime"])))
        }
        if let maximum = number(data["proMonthlyCredits"]), maximum > 0,
           let remaining = number(data["periodicCredits"]), (0...maximum).contains(remaining) {
            windows.append(QuotaWindow(kind: .additional(id: "manus.monthly", title: "Monthly"),
                usedPercent: (maximum - remaining) / maximum * 100, resetsAt: nil))
        }
        guard !windows.isEmpty else { throw ProviderFailure(.invalidResponse, "Manus returned no bounded quota.") }
        return ProviderSnapshot(provider: .manus, planName: nil, windows: windows,
            fetchedAt: Date(), credentialSource: "Edge Default", usageScope: "Account allowance • Manus")
    }
    static func kimi(subscription: HTTPResponse, stats: HTTPResponse, code: HTTPResponse? = nil) throws -> ProviderSnapshot {
        let account = try body(subscription), usage = try body(stats)
        var windows: [QuotaWindow] = []
        var notices: [ProviderUsageDetail] = []
        var balances = usage["balances"] as? [[String: Any]] ?? []
        if let primary = usage["subscriptionBalance"] as? [String: Any] { balances.insert(primary, at: 0) }
        for balance in balances {
            guard let feature = balance["feature"] as? String else { continue }
            guard let raw = balance["amountUsedRatio"], !(raw is NSNull) else { continue }
            let kind: QuotaKind = feature == "FEATURE_OMNI" ? .totalUsage : .additional(id: "kimi.membership." + feature,
                title: QuotaDiscovery.name(feature.replacingOccurrences(of: "FEATURE_", with: "")))
            if let ratio = number(raw), (0...1).contains(ratio) {
                if !windows.contains(where: { $0.kind == kind }) {
                    windows.append(QuotaWindow(kind: kind, usedPercent: ratio * 100, resetsAt: date(balance["expireTime"])))
                }
            } else { notices.append(QuotaDiscovery.notice(feature)) }
        }
        if let code {
            if let value = try? body(code) {
                for row in value["usages"] as? [[String: Any]] ?? [] {
                    guard let scope = row["scope"] as? String else { continue }
                    let name = QuotaDiscovery.name(scope.replacingOccurrences(of: "FEATURE_", with: ""))
                    var entries: [(String, String, [String: Any])] = []
                    if let detail = row["detail"] as? [String: Any] { entries.append(("total", name + " quota", detail)) }
                    for limit in row["limits"] as? [[String: Any]] ?? [] {
                        guard let window = limit["window"] as? [String: Any], let duration = number(window["duration"]),
                              let unit = window["timeUnit"] as? String, let detail = limit["detail"] as? [String: Any] else { continue }
                        entries.append(("\(duration).\(unit)", name + " · \(duration.formatted()) " + unit.replacingOccurrences(of: "TIME_UNIT_", with: "").lowercased(), detail))
                    }
                    for (suffix, title, detail) in entries {
                        let id = "kimi.code." + scope + "." + suffix
                        if let maximum = number(detail["limit"]), maximum > 0,
                           let remaining = number(detail["remaining"]), (0...maximum).contains(remaining) {
                            let kind = QuotaKind.additional(id: id, title: title)
                            if !windows.contains(where: { $0.kind == kind }) {
                                windows.append(QuotaWindow(kind: kind, usedPercent: (maximum - remaining) / maximum * 100,
                                    resetsAt: date(detail["resetTime"])))
                            }
                        } else if detail["limit"] != nil && !(detail["limit"] is NSNull) { notices.append(QuotaDiscovery.notice(id)) }
                    }
                }
            } else { notices.append(QuotaDiscovery.notice("Kimi Code")) }
        }
        guard !windows.isEmpty else { throw ProviderFailure(.invalidResponse, "Kimi returned no bounded usage.") }
        let sub = account["subscription"] as? [String: Any]
        let goods = sub?["goods"] as? [String: Any]
        return ProviderSnapshot(provider: .kimi, planName: goods?["title"] as? String, windows: windows,
            fetchedAt: Date(), credentialSource: "Kimi desktop", usageScope: "Membership usage • Kimi", usageDetails: notices)
    }
}
