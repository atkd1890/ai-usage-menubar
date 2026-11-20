import CryptoKit
import Foundation

actor AdobeProvider: UsageProvider {
    nonisolated let id = ProviderID.adobe

    static let authOrigin = "https://adobeid-na1.services.adobe.com"
    static let fireflyOrigin = "https://firefly.adobe.io"
    static let clientID = "SunbreakWebUI1"
    static let redirectURI = "https://account.adobe.com"
    static let scopes = "AdobeID,openid,firefly_api"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private let http: any HTTPClient
    private let loadCookies: @Sendable () throws -> (cookie: String, sourceLabel: String)
    private let dateProvider: @Sendable () -> Date

    init(
        http: any HTTPClient = GeminiReadOnlyHTTPClient(allowedHosts: ["adobeid-na1.services.adobe.com", "firefly.adobe.io"]),
        cookies: (@Sendable () throws -> (cookie: String, sourceLabel: String))? = nil,
        method: (@Sendable () -> ProviderLoginMethod)? = nil,
        sessions: WebSessionStore = WebSessionStore(),
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http
        self.dateProvider = dateProvider

        if let cookies {
            self.loadCookies = cookies
        } else {
            let resolveMethod = method ?? { ProviderLoginMethod.selected(for: .adobe) }
            self.loadCookies = {
                let selected = resolveMethod()
                let source: WebSessionSource = selected == .chrome ? .chrome : .edge
                let label = selected == .chrome ? "Chrome Default" : "Edge Default"
                let header = try sessions.cookies(source: source, domain: "services.adobe.com", names: ["ims_sid"])
                return (header, label)
            }
        }
    }

    func fetch() async throws -> ProviderSnapshot {
        let (cookieHeader, sourceLabel) = try loadCookies()
        guard let imsSid = Self.cookieValue(named: "ims_sid", in: cookieHeader), !imsSid.isEmpty else {
            throw ProviderFailure(.authentication, "Sign in to Adobe in \(sourceLabel).")
        }

        let queryParams = [
            "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI,
            "scope": Self.scopes,
            "response_type": "token",
            "prompt": "none"
        ]
        var components = URLComponents(string: "\(Self.authOrigin)/ims/authorize/v1")!
        components.queryItems = queryParams.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let authURL = components.url else {
            throw ProviderFailure(.invalidResponse, "Invalid Adobe authorization URL.")
        }

        let authRequest = HTTPRequest(
            method: .get,
            url: authURL,
            headers: [
                "Cookie": "ims_sid=\(imsSid)",
                "User-Agent": Self.userAgent,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
            ],
            body: nil
        )

        let authResponse = try await http.send(authRequest)
        guard let accessToken = Self.extractAccessToken(from: authResponse) else {
            throw ProviderFailure(.authentication, "Sign in to Adobe in \(sourceLabel).")
        }

        guard let balanceURL = URL(string: "\(Self.fireflyOrigin)/v1/credits/balance") else {
            throw ProviderFailure(.invalidResponse, "Invalid Adobe balance URL.")
        }

        let balanceRequest = HTTPRequest(
            method: .get,
            url: balanceURL,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "x-api-key": Self.clientID,
                "Origin": "https://account.adobe.com",
                "Referer": "https://account.adobe.com/plans",
                "Accept": "application/json",
                "User-Agent": Self.userAgent
            ],
            body: nil
        )

        let balanceResponse = try await http.send(balanceRequest)
        guard balanceResponse.statusCode == 200 else {
            if balanceResponse.statusCode == 401 || balanceResponse.statusCode == 403 {
                throw ProviderFailure(.authentication, "Sign in to Adobe in \(sourceLabel).")
            }
            throw ProviderFailure(.invalidResponse, "Adobe balance endpoint returned HTTP \(balanceResponse.statusCode).")
        }

        return try Self.map(
            data: balanceResponse.body,
            accessToken: accessToken,
            credentialSource: sourceLabel,
            now: dateProvider()
        )
    }

    static func cookieValue(named name: String, in header: String) -> String? {
        let prefix = "\(name)="
        for item in header.components(separatedBy: ";") {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(prefix) {
                let value = String(trimmed.dropFirst(prefix.count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    static func extractAccessToken(from response: HTTPResponse) -> String? {
        if let location = response.header("location") {
            if let token = extractToken(from: location) {
                return token
            }
        }

        let body = String(decoding: response.body, as: UTF8.self)
        if let token = extractToken(from: body) {
            return token
        }

        return nil
    }

    private static func extractToken(from text: String) -> String? {
        let pattern = #"[#&?]access_token=([^&"'>\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let matched = String(text[range])
        return matched.removingPercentEncoding ?? matched
    }

    static func map(
        data: Data,
        accessToken: String,
        credentialSource: String,
        now: Date
    ) throws -> ProviderSnapshot {
        let balance: AdobeBalanceResponse
        do {
            balance = try JSONDecoder().decode(AdobeBalanceResponse.self, from: data)
        } catch {
            throw ProviderFailure(.invalidResponse, "Unable to parse Adobe credit balance.")
        }

        var windows: [QuotaWindow] = []
        let resetsAt = balance.total?.availableUntil.flatMap(parseISO8601)

        // 1. Monthly (Total Generative Credits)
        if let totalQuota = balance.total?.quota, let totalLimit = totalQuota.total {
            let used = totalQuota.used ?? 0
            let available = totalQuota.available ?? max(totalLimit - used, 0)
            let usedPercent = totalLimit > 0 ? (used / totalLimit) * 100.0 : 0
            windows.append(
                QuotaWindow(
                    kind: .monthly,
                    usedPercent: min(max(usedPercent, 0), 100),
                    resetsAt: resetsAt,
                    remainingCount: available,
                    limitCount: totalLimit
                )
            )
        }

        // 2. Firefly Plan Credit (Secondary Quota Window)
        if let fireflyItem = balance.credits?["firefly_plan_credit"] ?? balance.credits?.first(where: { $0.key.contains("firefly") })?.value,
           let fireflyQuota = fireflyItem.quota,
           let fireflyLimit = fireflyQuota.total {
            let used = fireflyQuota.used ?? 0
            let available = fireflyQuota.available ?? max(fireflyLimit - used, 0)
            let usedPercent = fireflyLimit > 0 ? (used / fireflyLimit) * 100.0 : 0
            let fireflyResetsAt = fireflyItem.availableUntil.flatMap(parseISO8601) ?? resetsAt
            windows.append(
                QuotaWindow(
                    kind: .firefly,
                    usedPercent: min(max(usedPercent, 0), 100),
                    resetsAt: fireflyResetsAt,
                    remainingCount: available,
                    limitCount: fireflyLimit
                )
            )
        }

        guard !windows.isEmpty else {
            throw ProviderFailure(.invalidResponse, "No Adobe generative quota found in balance response.")
        }
        if !windows.contains(where: { $0.kind == .monthly }) {
            windows.insert(QuotaWindow(
                kind: .monthly,
                usedPercent: 0,
                resetsAt: nil,
                isInactive: true,
                inactiveDetail: "No plan"
            ), at: 0)
        }
        if !windows.contains(where: { $0.kind == .firefly }) {
            windows.append(QuotaWindow(
                kind: .firefly,
                usedPercent: 0,
                resetsAt: nil,
                isInactive: true,
                inactiveDetail: "No Firefly plan"
            ))
        }

        let email = AccountEmail.jwt(accessToken)

        return ProviderSnapshot(
            provider: .adobe,
            planName: "Creative Cloud",
            windows: windows,
            fetchedAt: now,
            credentialSource: credentialSource,
            accountLabel: email ?? "Adobe Account",
            accountEmail: email
        )
    }

    static func parseISO8601(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let standard = ISO8601DateFormatter()
        return standard.date(from: string)
    }
}

private struct AdobeBalanceResponse: Decodable {
    struct QuotaInfo: Decodable {
        let total: Double?
        let used: Double?
        let available: Double?
    }

    struct TotalInfo: Decodable {
        let quota: QuotaInfo?
        let planCap: String?
        let availableUntil: String?
    }

    struct CreditItem: Decodable {
        let quota: QuotaInfo?
        let availableUntil: String?
    }

    let total: TotalInfo?
    let credits: [String: CreditItem]?
}
