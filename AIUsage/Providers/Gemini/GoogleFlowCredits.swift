import CryptoKit
import Foundation

enum MediaCreditReading: Equatable, Sendable {
    case available(balance: Double, resetsAt: Date?)
    case unavailable(status: String)
}

struct GoogleFlowCreditsResult: Equatable, Sendable {
    let flow: MediaCreditReading?
    let music: MediaCreditReading?
    let diagnosticWarnings: [ProviderDiagnosticWarning]

    static let empty = GoogleFlowCreditsResult(flow: nil, music: nil, diagnosticWarnings: [])

    var isEmpty: Bool {
        flow == nil && music == nil && diagnosticWarnings.isEmpty
    }
}

/// Optional Google media-credit balances rendered as two side-by-side detail quota tiles in the Gemini card.
/// Both are read-only and browser-bound: Google Flow uses `.google.com` + `flow.google.com` `__Secure-OSID`;
/// Flow Music uses its own Supabase session cookie on `www.flowmusic.app`.
actor GoogleFlowCredits {
    static let flowHost = "flow.google.com"
    static let flowOSIDCookieName = "__Secure-OSID"
    static let flowMusicHost = "www.flowmusic.app"
    static let flowRPC = "nzlxg"
    /// Supabase SSR stores one session as chunked cookies; read only these exact names.
    static let flowMusicCookieNames = ["sb-sb-auth-token"] + (0..<8).map { "sb-sb-auth-token.\($0)" }

    private let authStore: GeminiAuthStore
    private let flowHTTP: any HTTPClient
    private let musicHTTP: any HTTPClient
    private let dateProvider: any DateProviding
    /// The page-issued `at` form token, bound to the Google + Flow session that produced it.
    private var cachedFlowToken: (fingerprint: Data, token: String)?

    init(authStore: GeminiAuthStore = GeminiAuthStore(),
         flowHTTP: any HTTPClient = GeminiReadOnlyHTTPClient(allowedHosts: [GoogleFlowCredits.flowHost]),
         musicHTTP: any HTTPClient = GeminiReadOnlyHTTPClient(allowedHosts: [GoogleFlowCredits.flowMusicHost]),
         dateProvider: any DateProviding = SystemDateProvider()) {
        self.authStore = authStore
        self.flowHTTP = flowHTTP
        self.musicHTTP = musicHTTP
        self.dateProvider = dateProvider
    }

    /// Never throws. Desktop app only never reads a browser and omits browser-only media tiles;
    /// browser-backed modes fetch Flow and Flow Music concurrently and degrade independently to `N/A` / `Expired`.
    func fetch(source: GeminiCredentialSource, googleSession: GeminiWebSession?) async -> GoogleFlowCreditsResult {
        guard source.browser != nil else { return .empty }
        let flowSession = buildFlowSession(source: source, googleSession: googleSession)
        async let flowTask: (reading: MediaCreditReading, warnings: [ProviderDiagnosticWarning]) = {
            if let flowSession {
                return await flowDetails(session: flowSession)
            }
            return (.unavailable(status: "N/A"), [])
        }()
        async let musicTask = flowMusicDetails(source: source)
        let (flowResult, musicResult) = await (flowTask, musicTask)
        return GoogleFlowCreditsResult(
            flow: flowResult.reading,
            music: musicResult.reading,
            diagnosticWarnings: ResponseSchemaWatch.deduplicated(flowResult.warnings + musicResult.warnings)
        )
    }

    // MARK: Plan Allotments & QuotaWindows

    static func flowAllotment(forPlan planName: String?) -> Double {
        let lower = planName?.lowercased() ?? ""
        if lower.contains("ultra") { return 25_000 }
        if lower.contains("pro") { return 1_000 }
        if lower.contains("free") { return 100 }
        return 1_000
    }

    static func flowMusicAllotment(forPlan planName: String?) -> Double {
        let lower = planName?.lowercased() ?? ""
        if lower.contains("ultra") { return 30_000 }
        if lower.contains("pro") { return 10_000 }
        if lower.contains("free") { return 100 }
        return 10_000
    }

    static func window(id: String, title: String, reading: MediaCreditReading, allotment: Double) -> QuotaWindow {
        switch reading {
        case let .available(balance, resetsAt):
            let clampedBalance = max(balance, 0)
            let limit = max(allotment, clampedBalance)
            let usedPercent = limit > 0 ? min(max((limit - clampedBalance) / limit * 100, 0), 100) : 0
            return QuotaWindow(
                kind: .additional(id: id, title: title),
                usedPercent: usedPercent,
                resetsAt: resetsAt,
                remainingCount: clampedBalance,
                limitCount: limit
            )
        case let .unavailable(status):
            return QuotaWindow(
                kind: .additional(id: id, title: title),
                usedPercent: 0,
                resetsAt: nil,
                isInactive: true,
                inactiveDetail: status
            )
        }
    }

    // MARK: Google Flow

    private func buildFlowSession(source: GeminiCredentialSource, googleSession: GeminiWebSession?) -> GeminiWebSession? {
        guard let base = googleSession ?? (try? authStore.loadSession(source: source)) else { return nil }
        let flowCookies = (try? authStore.loadCookies(source: source, host: Self.flowHost, names: [Self.flowOSIDCookieName])) ?? [:]
        guard let secureOSID = flowCookies[Self.flowOSIDCookieName],
              !base.cookieHeader.contains("\(Self.flowOSIDCookieName)=") else {
            return base
        }
        return GeminiWebSession(cookieHeader: base.cookieHeader + "; \(Self.flowOSIDCookieName)=\(secureOSID)")
    }

    struct ParsedFlow: Equatable, Sendable {
        let balance: Double
        let resetsAt: Date?
    }

    private func flowDetails(session: GeminiWebSession) async -> (reading: MediaCreditReading, warnings: [ProviderDiagnosticWarning]) {
        let now = dateProvider.now()
        let fingerprint = Data(SHA256.hash(data: Data(session.cookieHeader.utf8)))
        do {
            for attempt in 0..<2 {
                let token: String
                let usedCachedToken: Bool
                if attempt == 0, let cached = cachedFlowToken, cached.fingerprint == fingerprint {
                    token = cached.token
                    usedCachedToken = true
                } else {
                    cachedFlowToken = nil
                    token = try await fetchFlowToken(session: session)
                    cachedFlowToken = (fingerprint, token)
                    usedCachedToken = false
                }
                let response = try await flowHTTP.send(Self.flowRequest(session: session, token: token))
                let parsed = Self.parseFlow(response: response, now: now)
                // A stale `at` token may fail with 400/401 or a 200 error/null payload; refetch once when cached.
                if attempt == 0, ([400, 401].contains(response.statusCode) || (usedCachedToken && parsed == nil)) {
                    cachedFlowToken = nil
                    continue
                }
                if let parsed {
                    let warnings = ResponseSchemaWatch.httpHeaders(response, provider: .gemini, endpoint: "Gemini Flow")
                    return (.available(balance: parsed.balance, resetsAt: parsed.resetsAt), warnings)
                }
                cachedFlowToken = nil
                return (.unavailable(status: "N/A"), [])
            }
            cachedFlowToken = nil
            return (.unavailable(status: "N/A"), [])
        } catch {
            cachedFlowToken = nil
            return (.unavailable(status: "N/A"), [])
        }
    }

    private func fetchFlowToken(session: GeminiWebSession) async throws -> String {
        let response = try await flowHTTP.send(HTTPRequest(method: .get, url: URL(string: "https://\(Self.flowHost)/")!, headers: [
            "Accept": "text/html",
            "Cookie": session.cookieHeader
        ]))
        guard response.statusCode == 200, let token = Self.pageToken(in: response.body) else {
            throw ProviderFailure(.authentication, "Google Flow session is unavailable.")
        }
        return token
    }

    static func pageToken(in body: Data) -> String? {
        let html = String(decoding: body, as: UTF8.self)
        guard let marker = html.range(of: "\"SNlM0e\":\"") else { return nil }
        let tail = html[marker.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        let token = String(tail[..<end])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:."))
        guard !token.isEmpty, token.count < 512, token.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return token
    }

    static func flowRequest(session: GeminiWebSession, token: String) -> HTTPRequest {
        var url = URLComponents(string: "https://\(flowHost)/_/AiSandboxAngularFrontend/data/batchexecute")!
        url.queryItems = [URLQueryItem(name: "rpcids", value: flowRPC), URLQueryItem(name: "source-path", value: "/"),
                          URLQueryItem(name: "hl", value: "en"), URLQueryItem(name: "rt", value: "c")]
        let request = #"[[["\#(flowRPC)","[]",null,"generic"]]]"#
        let body = "f.req=\(formEncoded(request))&at=\(formEncoded(token))"
        return HTTPRequest(method: .post, url: url.url!, headers: [
            "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
            "Origin": "https://\(flowHost)",
            "Referer": "https://\(flowHost)/",
            "Cookie": session.cookieHeader
        ], body: Data(body.utf8))
    }

    static func formEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    static func parseFlow(response: HTTPResponse, now: Date) -> ParsedFlow? {
        guard response.statusCode == 200,
              let payload = batchPayload(rpc: flowRPC, in: response.body),
              let values = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [Any],
              let balance = QuotaDiscovery.number(values.first), balance.isFinite, balance >= 0 else {
            return nil
        }
        var resetsAt: Date?
        if values.count > 6, let stamp = values[6] as? [Any], let seconds = QuotaDiscovery.number(stamp.first),
           seconds.isFinite, seconds > 0 {
            let candidate = Date(timeIntervalSince1970: seconds)
            if candidate > now {
                resetsAt = candidate
            }
        }
        return ParsedFlow(balance: balance, resetsAt: resetsAt)
    }

    /// Extracts the JSON string payload of one `wrb.fr` entry from a batchexecute response (chunked or not).
    static func batchPayload(rpc: String, in body: Data) -> String? {
        var text = String(decoding: body, as: UTF8.self)
        if text.hasPrefix(")]}'") { text = String(text.dropFirst(4)) }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["),
                  let rows = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [Any] else { continue }
            for case let row as [Any] in rows where row.count > 2 {
                if row[0] as? String == "wrb.fr", row[1] as? String == rpc, let payload = row[2] as? String { return payload }
            }
        }
        return nil
    }

    // MARK: Flow Music

    private func flowMusicDetails(source: GeminiCredentialSource) async -> (reading: MediaCreditReading, warnings: [ProviderDiagnosticWarning]) {
        let cookies: [String: String]
        do { cookies = try authStore.loadCookies(source: source, host: Self.flowMusicHost, names: Self.flowMusicCookieNames) }
        catch { return (.unavailable(status: "N/A"), []) }
        guard !cookies.isEmpty, let session = Self.flowMusicSession(cookies: cookies) else {
            return (.unavailable(status: "N/A"), [])
        }
        // Never refresh: Supabase rotates refresh tokens, which would sign the browser out.
        guard session.expiresAt.timeIntervalSince(dateProvider.now()) > 60 else { return (.unavailable(status: "Expired"), []) }
        do {
            let response = try await musicHTTP.send(HTTPRequest(method: .get,
                url: URL(string: "https://\(Self.flowMusicHost)/__api/billing/credits")!, headers: [
                    "Accept": "application/json",
                    "Authorization": "Bearer \(session.accessToken)"
                ]))
            return Self.mapFlowMusic(response: response)
        } catch {
            return (.unavailable(status: "N/A"), [])
        }
    }

    struct FlowMusicSession: Equatable, Sendable {
        let accessToken: String
        let expiresAt: Date
    }

    static func flowMusicSession(cookies: [String: String]) -> FlowMusicSession? {
        var raw: String
        if let single = cookies["sb-sb-auth-token"] { raw = single }
        else {
            var chunks: [String] = []
            for index in 0..<8 {
                guard let chunk = cookies["sb-sb-auth-token.\(index)"] else { break }
                chunks.append(chunk)
            }
            guard !chunks.isEmpty else { return nil }
            raw = chunks.joined()
        }
        raw = raw.removingPercentEncoding ?? raw
        let json: Data
        if raw.hasPrefix("base64-") {
            guard let decoded = ProviderParsing.base64URLData(String(raw.dropFirst(7))) else { return nil }
            json = decoded
        } else {
            json = Data(raw.utf8)
        }
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let token = object["access_token"] as? String,
              !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0 == ";" }) else { return nil }
        let expiry = QuotaDiscovery.number(object["expires_at"]).map { Date(timeIntervalSince1970: $0) }
            ?? jwtExpiration(token)
        guard let expiry else { return nil }
        return FlowMusicSession(accessToken: token, expiresAt: expiry)
    }

    static func jwtExpiration(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let data = ProviderParsing.base64URLData(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = QuotaDiscovery.number(object["exp"]) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func mapFlowMusic(response: HTTPResponse) -> (reading: MediaCreditReading, warnings: [ProviderDiagnosticWarning]) {
        if [401, 403].contains(response.statusCode) { return (.unavailable(status: "Expired"), []) }
        guard response.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            return (.unavailable(status: "N/A"), [])
        }
        var warnings = ResponseSchemaWatch.httpHeaders(response, provider: .gemini, endpoint: "Gemini Flow Music")
        warnings += ResponseSchemaWatch.jsonBodyDeprecation(object, provider: .gemini, endpoint: "Gemini Flow Music")
        warnings += ResponseSchemaWatch.confirmedJSONKeys(in: object, provider: .gemini, endpoint: "Gemini Flow Music")
        guard let data = object["data"] as? [String: Any] else {
            return (.unavailable(status: "N/A"), ResponseSchemaWatch.deduplicated(warnings))
        }
        warnings += ResponseSchemaWatch.confirmedJSONKeys(in: data, provider: .gemini, endpoint: "Gemini Flow Music data")
        guard let credits = QuotaDiscovery.number(data["credits_remaining"]), credits.isFinite, credits >= 0 else {
            return (.unavailable(status: "N/A"), ResponseSchemaWatch.deduplicated(warnings))
        }
        return (.available(balance: credits, resetsAt: nil), ResponseSchemaWatch.deduplicated(warnings))
    }
}
