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
    private let method: @Sendable () -> ProviderLoginMethod
    private let kimiSessionStore: KimiSessionStore?
    private let now: @Sendable () -> Date
    private var kimiCache: (fingerprint: Data, session: KimiNativeSession)?
    private var refreshTask: (fingerprint: Data, task: Task<KimiNativeSession, Error>)?

    init(id: ProviderID, http: (any HTTPClient)? = nil, sessions: WebSessionStore = WebSessionStore(),
         nativeKimi: @escaping @Sendable () throws -> KimiNativeSession = { try KimiNativeSession.load() },
         allowRefresh: @escaping @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: "kimiNativeRefreshAllowed.v1") },
         method: (@Sendable () -> ProviderLoginMethod)? = nil,
         kimiSessionStore: KimiSessionStore? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.id = id; self.sessions = sessions
        self.nativeKimi = nativeKimi; self.allowRefresh = allowRefresh
        self.method = method ?? { ProviderLoginMethod.selected(for: id) }
        self.kimiSessionStore = kimiSessionStore ?? (http == nil ? KimiSessionStore() : nil)
        self.now = now
        self.http = http ?? GeminiReadOnlyHTTPClient(allowedHosts: [id == .manus ? "api.manus.im" : "www.kimi.ai"])
    }
    func fetch() async throws -> ProviderSnapshot {
        let token: String
        if id == .manus {
            let selectedMethod = method()
            let (source, label): (WebSessionSource, String) = switch selectedMethod {
            case .desktop: (.manusDesktop, "Manus desktop")
            case .chrome: (.chrome, "Chrome Default")
            default: (.edge, "Edge Default")
            }
            let cookie = try sessions.cookies(source: source, domain: "manus.im", names: ["session_id"])
            guard cookie.hasPrefix("session_id=") else { throw ProviderFailure(.authentication, "Sign in to Manus in \(label).") }
            token = String(cookie.dropFirst("session_id=".count))
            let fingerprint = Data(SHA256.hash(data: Data((label + "\0" + token).utf8)))
                .map { String(format: "%02x", $0) }.joined()
            return try Self.manus(
                await request("https://api.manus.im/user.v1.UserService/GetAvailableCredits", token: token),
                credentialSource: label,
                accountLabel: "manus-session:" + fingerprint
            )
        }
        guard id == .kimi else { throw ProviderFailure(.invalidResponse, "Unsupported consumer provider.") }
        let load = nativeKimi
        let native = try await Task.detached(priority: .utility) { try load() }.value
        let fingerprint = Data(SHA256.hash(data: Data((native.sourceLabel + "\0" + native.access + "\0" + (native.refresh ?? "")).utf8)))
        let fingerprintHex = fingerprint.map { String(format: "%02x", $0) }.joined()
        let historyID = "kimi-session:" + Data(SHA256.hash(data: Data((native.sourceLabel + "\0" + (native.refresh ?? native.access)).utf8))).map { String(format: "%02x", $0) }.joined()

        var session: KimiNativeSession
        if kimiCache?.fingerprint == fingerprint {
            session = kimiCache!.session
        } else if let persisted = kimiSessionStore?.load(for: native.sourceLabel) {
            if persisted.seedFingerprint == fingerprintHex, KimiNativeSession.valid(persisted.accessToken) {
                let persistedRefresh = persisted.refreshToken.flatMap { KimiNativeSession.valid($0) ? $0 : nil } ?? native.refresh
                session = KimiNativeSession(access: persisted.accessToken, refresh: persistedRefresh, sourceLabel: native.sourceLabel)
                kimiCache = (fingerprint, session)
            } else {
                kimiSessionStore?.remove(for: native.sourceLabel)
                session = native
            }
        } else {
            session = native
        }

        if allowRefresh(),
           let expiresAt = KimiNativeSession.jwtClaims(session.access)?.expiresAt,
           expiresAt <= now().addingTimeInterval(120),
           session.refresh != nil {
            session = try await refreshed(
                session,
                fingerprint: fingerprint,
                seedFingerprintHex: fingerprintHex,
                fallbackRefresh: native.refresh
            )
        }

        for attempt in 0...1 {
            let subscription = try await request("https://www.kimi.ai/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscription", token: session.access)
            if subscription.statusCode == 401 {
                if attempt == 0 {
                    session = try await refreshed(
                        session,
                        fingerprint: fingerprint,
                        seedFingerprintHex: fingerprintHex,
                        fallbackRefresh: native.refresh
                    )
                    continue
                }
                kimiCache = nil
                kimiSessionStore?.remove(for: session.sourceLabel)
                throw ProviderFailure(.authentication, "Kimi session expired. Sign in to \(session.sourceLabel) again.")
            }
            _ = try Self.body(subscription)
            let stats = try await request("https://www.kimi.ai/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats", token: session.access)
            if stats.statusCode == 401 {
                if attempt == 0 {
                    session = try await refreshed(
                        session,
                        fingerprint: fingerprint,
                        seedFingerprintHex: fingerprintHex,
                        fallbackRefresh: native.refresh
                    )
                    continue
                }
                kimiCache = nil
                kimiSessionStore?.remove(for: session.sourceLabel)
                throw ProviderFailure(.authentication, "Kimi session expired. Sign in to \(session.sourceLabel) again.")
            }
            let code = try? await request("https://www.kimi.ai/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages", token: session.access,
                payload: Data(#"{"scope":["FEATURE_CODING"]}"#.utf8))
            return try Self.kimi(
                subscription: subscription,
                stats: stats,
                code: code ?? HTTPResponse(statusCode: 503, headers: [:], body: Data()),
                credentialSource: session.sourceLabel,
                accountLabel: historyID
            )
        }
        throw ProviderFailure(.authentication, "Kimi session expired. Sign in to \(session.sourceLabel) again.")
    }
    private static func sendRefresh(http: any HTTPClient, refreshToken: String) async throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer " + refreshToken,
            "Accept": "application/json",
            "Origin": "https://www.kimi.ai",
            "User-Agent": "Mozilla/5.0"
        ]
        for (key, value) in KimiNativeSession.sessionHeaders(for: refreshToken) {
            headers[key] = value
        }
        return try await http.send(HTTPRequest(
            method: .get,
            url: URL(string: "https://www.kimi.ai/api/auth/token/refresh")!,
            headers: headers,
            body: nil
        ))
    }
    private func refreshed(
        _ session: KimiNativeSession,
        fingerprint: Data,
        seedFingerprintHex: String,
        fallbackRefresh: String?
    ) async throws -> KimiNativeSession {
        guard allowRefresh(), let refresh = session.refresh, KimiNativeSession.valid(refresh) else {
            throw ProviderFailure(.authentication, "Kimi session expired. Open \(session.sourceLabel) to renew the login.")
        }
        if let active = refreshTask, active.fingerprint == fingerprint { return try await active.task.value }
        let http = self.http
        let sourceLabel = session.sourceLabel
        let task = Task<KimiNativeSession, Error> {
            var response = try await Self.sendRefresh(http: http, refreshToken: refresh)
            if [401, 403].contains(response.statusCode),
               let fallback = fallbackRefresh,
               fallback != refresh,
               KimiNativeSession.valid(fallback) {
                response = try await Self.sendRefresh(http: http, refreshToken: fallback)
            }
            if [401, 403].contains(response.statusCode) {
                throw ProviderFailure(.authentication, "Kimi session expired. Sign in to \(sourceLabel) again.")
            }
            let body = try Self.body(response)
            guard let rawAccess = (body["access_token"] ?? body["accessToken"]) as? String else {
                throw ProviderFailure(.invalidResponse, "Kimi refresh returned no valid access token.")
            }
            let access = KimiNativeSession.stripBearer(rawAccess)
            guard KimiNativeSession.valid(access) else {
                throw ProviderFailure(.invalidResponse, "Kimi refresh returned no valid access token.")
            }
            let rawNext = (body["refresh_token"] ?? body["refreshToken"]) as? String ?? refresh
            let next = KimiNativeSession.stripBearer(rawNext)
            guard KimiNativeSession.valid(next) else { throw ProviderFailure(.invalidResponse, "Kimi refresh returned an invalid session.") }
            return KimiNativeSession(access: access, refresh: next, sourceLabel: sourceLabel)
        }
        refreshTask = (fingerprint, task)
        defer { if refreshTask?.fingerprint == fingerprint { refreshTask = nil } }
        do {
            let updated = try await task.value
            kimiCache = (fingerprint, updated)
            kimiSessionStore?.save(
                KimiPersistedSession(
                    seedFingerprint: seedFingerprintHex,
                    accessToken: updated.access,
                    refreshToken: updated.refresh,
                    updatedAt: now()
                ),
                for: session.sourceLabel
            )
            return updated
        } catch let failure as ProviderFailure where failure.kind == .authentication {
            kimiCache = nil
            kimiSessionStore?.remove(for: session.sourceLabel)
            throw failure
        }
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
            for (key, value) in KimiNativeSession.sessionHeaders(for: token) {
                headers[key] = value
            }
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
    static func manus(
        _ response: HTTPResponse,
        credentialSource: String = "Edge Default",
        accountLabel: String? = nil
    ) throws -> ProviderSnapshot {
        let root = try body(response)
        let data = (root["data"] ?? root["result"] ?? root["response"] ?? root["availableCredits"]) as? [String: Any] ?? root
        var windows: [QuotaWindow] = []
        var details: [ProviderUsageDetail] = []
        if let maximum = number(data["maxRefreshCredits"]), maximum > 0,
           let remaining = number(data["refreshCredits"]), (0...maximum).contains(remaining) {
            windows.append(QuotaWindow(
                kind: .daily,
                usedPercent: (maximum - remaining) / maximum * 100,
                resetsAt: date(data["nextRefreshTime"]),
                remainingCount: remaining,
                limitCount: maximum
            ))
        }
        if let maximum = number(data["proMonthlyCredits"]), maximum > 0,
           let remaining = number(data["periodicCredits"]), (0...maximum).contains(remaining) {
            windows.append(QuotaWindow(
                kind: .additional(id: "manus.monthly", title: "Monthly"),
                usedPercent: (maximum - remaining) / maximum * 100,
                resetsAt: nil,
                remainingCount: remaining,
                limitCount: maximum
            ))
        }
        var creditParts: [String] = []
        if let free = number(data["freeCredits"]), free > 0 {
            creditParts.append("Free \(Int(free.rounded()).formatted(.number))")
        }
        if let addOn = number(data["addOnCredits"]), addOn > 0 {
            creditParts.append("Add-on \(Int(addOn.rounded()).formatted(.number))")
        }
        if let total = number(data["totalCredits"]), total > 0 {
            creditParts.append("Total \(Int(total.rounded()).formatted(.number))")
        }
        if !creditParts.isEmpty {
            details.append(ProviderUsageDetail(
                id: "manus.credits",
                title: "Additional Credits",
                value: creditParts.joined(separator: " · ")
            ))
        }
        guard !windows.isEmpty else { throw ProviderFailure(.invalidResponse, "Manus returned no bounded quota.") }
        return ProviderSnapshot(provider: .manus, planName: nil, windows: windows,
            fetchedAt: Date(), credentialSource: credentialSource, accountLabel: accountLabel,
            usageScope: "Account allowance • Manus", usageDetails: details)
    }
    static func kimi(
        subscription: HTTPResponse,
        stats: HTTPResponse,
        code: HTTPResponse? = nil,
        credentialSource: String = "Kimi desktop",
        accountLabel: String? = nil
    ) throws -> ProviderSnapshot {
        let account = try body(subscription), usage = try body(stats)
        var windows: [QuotaWindow] = []
        var notices: [ProviderUsageDetail] = []
        var balances = usage["balances"] as? [[String: Any]] ?? []
        if balances.isEmpty, let accountBalances = account["balances"] as? [[String: Any]] {
            balances = accountBalances
        }
        if let primary = usage["subscriptionBalance"] as? [String: Any] { balances.insert(primary, at: 0) }
        for balance in balances {
            guard let feature = balance["feature"] as? String else { continue }
            guard let raw = balance["amountUsedRatio"], !(raw is NSNull) else { continue }
            let kind: QuotaKind = feature == "FEATURE_OMNI" ? .monthly : .additional(id: "kimi.membership." + feature,
                title: QuotaDiscovery.name(feature.replacingOccurrences(of: "FEATURE_", with: "")))
            if let ratio = number(raw), (0...1).contains(ratio) {
                if !windows.contains(where: { $0.kind == kind }) {
                    windows.append(QuotaWindow(kind: kind, usedPercent: ratio * 100, resetsAt: date(balance["expireTime"])))
                }
            } else { notices.append(QuotaDiscovery.notice(feature)) }
        }
        if let ratelimit = usage["ratelimitCode7d"] as? [String: Any],
           let raw = ratelimit["amountUsedRatio"], !(raw is NSNull) {
            if let ratio = number(raw), (0...1).contains(ratio) {
                let kind = QuotaKind.additional(id: "kimi.code.7d", title: "Kimi Code · Weekly")
                if !windows.contains(where: { $0.kind == kind }) {
                    windows.append(QuotaWindow(
                        kind: kind,
                        usedPercent: ratio * 100,
                        resetsAt: date(ratelimit["expireTime"] ?? ratelimit["resetTime"])
                    ))
                }
            } else {
                notices.append(QuotaDiscovery.notice("kimi.code.7d"))
            }
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
                                windows.append(QuotaWindow(
                                    kind: kind,
                                    usedPercent: (maximum - remaining) / maximum * 100,
                                    resetsAt: date(detail["resetTime"]),
                                    remainingCount: remaining,
                                    limitCount: maximum
                                ))
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
            fetchedAt: Date(), credentialSource: credentialSource, accountLabel: accountLabel,
            usageScope: "Monthly membership • Kimi", usageDetails: notices)
    }
}
