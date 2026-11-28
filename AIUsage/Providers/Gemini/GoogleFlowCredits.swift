import CryptoKit
import Foundation

enum MediaCreditReading: Equatable, Sendable {
    case available(balance: Double, resetsAt: Date?)
    case unavailable(status: String)
}

enum BoundedCountReading: Equatable, Sendable {
    case available(used: Double, limit: Double, resetsAt: Date?)
    case unavailable(status: String)
}

enum PercentQuotaReading: Equatable, Sendable {
    case available(usedPercent: Double, resetsAt: Date?)
    case unavailable(status: String)
}

struct GoogleFlowCreditsResult: Equatable, Sendable {
    let flow: MediaCreditReading?
    let music: MediaCreditReading?
    let stitch: BoundedCountReading?
    let notebookLMSession: PercentQuotaReading?
    let notebookLMWeekly: PercentQuotaReading?
    let diagnosticWarnings: [ProviderDiagnosticWarning]

    init(flow: MediaCreditReading?,
         music: MediaCreditReading?,
         stitch: BoundedCountReading? = nil,
         notebookLMSession: PercentQuotaReading? = nil,
         notebookLMWeekly: PercentQuotaReading? = nil,
         diagnosticWarnings: [ProviderDiagnosticWarning]) {
        self.flow = flow
        self.music = music
        self.stitch = stitch
        self.notebookLMSession = notebookLMSession
        self.notebookLMWeekly = notebookLMWeekly
        self.diagnosticWarnings = diagnosticWarnings
    }

    static let empty = GoogleFlowCreditsResult(
        flow: nil,
        music: nil,
        stitch: nil,
        notebookLMSession: nil,
        notebookLMWeekly: nil,
        diagnosticWarnings: []
    )

    var isEmpty: Bool {
        flow == nil && music == nil && stitch == nil && notebookLMSession == nil && notebookLMWeekly == nil && diagnosticWarnings.isEmpty
    }
}

/// Optional Google media and product quota balances rendered as detail quota tiles in the Gemini card.
/// All are read-only and browser-bound: Google Flow, Stitch, and NotebookLM use `.google.com` + per-host
/// `__Secure-OSID`; Flow Music uses its own Supabase session cookie on `www.flowmusic.app`.
actor GoogleFlowCredits {
    static let flowHost = "flow.google.com"
    static let flowOSIDCookieName = "__Secure-OSID"
    static let flowMusicHost = "www.flowmusic.app"
    static let flowRPC = "nzlxg"
    static let flowBatchPath = "/_/AiSandboxAngularFrontend/data/batchexecute"
    static let stitchHost = "stitch.google.com"
    static let stitchRPC = "N5xENe"
    static let stitchBatchPath = "/_/Nemo/data/batchexecute"
    static let notebookLMHost = "notebook.google.com"
    static let notebookLMRPC = "EylDcb"
    static let notebookLMBatchPath = "/_/LabsTailwindUi/data/batchexecute"
    /// Supabase SSR stores one session as chunked cookies; read only these exact names.
    static let flowMusicCookieNames = ["sb-sb-auth-token"] + (0..<8).map { "sb-sb-auth-token.\($0)" }

    private let authStore: GeminiAuthStore
    private let flowHTTP: any HTTPClient
    private let musicHTTP: any HTTPClient
    private let stitchHTTP: any HTTPClient
    private let notebookLMHTTP: any HTTPClient
    private let dateProvider: any DateProviding
    /// Page-issued `at` form tokens, bound to the host + Google/host session that produced them.
    private var cachedPageTokens: [String: (fingerprint: Data, token: String)] = [:]

    init(authStore: GeminiAuthStore = GeminiAuthStore(),
         flowHTTP: any HTTPClient = GeminiReadOnlyHTTPClient(allowedHosts: [GoogleFlowCredits.flowHost]),
         musicHTTP: any HTTPClient = GeminiReadOnlyHTTPClient(allowedHosts: [GoogleFlowCredits.flowMusicHost]),
         stitchHTTP: any HTTPClient = GeminiReadOnlyHTTPClient(allowedHosts: [GoogleFlowCredits.stitchHost]),
         notebookLMHTTP: any HTTPClient = GeminiReadOnlyHTTPClient(allowedHosts: [GoogleFlowCredits.notebookLMHost]),
         dateProvider: any DateProviding = SystemDateProvider()) {
        self.authStore = authStore
        self.flowHTTP = flowHTTP
        self.musicHTTP = musicHTTP
        self.stitchHTTP = stitchHTTP
        self.notebookLMHTTP = notebookLMHTTP
        self.dateProvider = dateProvider
    }

    /// Never throws. Desktop app only never reads a browser and omits browser-only detail tiles;
    /// browser-backed modes fetch Flow, Flow Music, Stitch, and NotebookLM concurrently and degrade independently to `N/A` / `Expired`.
    func fetch(source: GeminiCredentialSource, googleSession: GeminiWebSession?) async -> GoogleFlowCreditsResult {
        guard source.browser != nil else { return .empty }
        let baseSession = googleSession ?? (try? authStore.loadSession(source: source))
        let flowSession = buildHostSession(source: source, googleSession: baseSession, host: Self.flowHost)
        let stitchSession = buildHostSession(source: source, googleSession: baseSession, host: Self.stitchHost)
        let notebookLMSession = buildHostSession(source: source, googleSession: baseSession, host: Self.notebookLMHost)

        async let flowTask: (reading: MediaCreditReading, warnings: [ProviderDiagnosticWarning]) = {
            if let flowSession {
                return await flowDetails(session: flowSession)
            }
            return (.unavailable(status: "N/A"), [])
        }()
        async let musicTask = flowMusicDetails(source: source)
        async let stitchTask: (reading: BoundedCountReading, warnings: [ProviderDiagnosticWarning]) = {
            if let stitchSession {
                return await stitchDetails(session: stitchSession)
            }
            return (.unavailable(status: "N/A"), [])
        }()
        async let notebookLMTask: (session: PercentQuotaReading, weekly: PercentQuotaReading, warnings: [ProviderDiagnosticWarning]) = {
            if let notebookLMSession {
                return await notebookLMDetails(session: notebookLMSession)
            }
            return (.unavailable(status: "N/A"), .unavailable(status: "N/A"), [])
        }()

        let (flowResult, musicResult, stitchResult, notebookLMResult) = await (flowTask, musicTask, stitchTask, notebookLMTask)
        return GoogleFlowCreditsResult(
            flow: flowResult.reading,
            music: musicResult.reading,
            stitch: stitchResult.reading,
            notebookLMSession: notebookLMResult.session,
            notebookLMWeekly: notebookLMResult.weekly,
            diagnosticWarnings: ResponseSchemaWatch.deduplicated(
                flowResult.warnings + musicResult.warnings + stitchResult.warnings + notebookLMResult.warnings
            )
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

    static func stitchWindow(id: String, title: String, reading: BoundedCountReading) -> QuotaWindow {
        switch reading {
        case let .available(used, limit, resetsAt):
            let clampedUsed = max(used, 0)
            let remaining = max(limit - clampedUsed, 0)
            let usedPercent = limit > 0 ? min(max(clampedUsed / limit * 100, 0), 100) : 0
            return QuotaWindow(
                kind: .additional(id: id, title: title),
                usedPercent: usedPercent,
                resetsAt: resetsAt,
                remainingCount: remaining,
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

    static func percentWindow(id: String, title: String, reading: PercentQuotaReading) -> QuotaWindow {
        switch reading {
        case let .available(usedPercent, resetsAt):
            return QuotaWindow(
                kind: .additional(id: id, title: title),
                usedPercent: min(max(usedPercent, 0), 100),
                resetsAt: resetsAt
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

    // MARK: Shared Wiz / batchexecute

    private func buildHostSession(source: GeminiCredentialSource, googleSession: GeminiWebSession?, host: String) -> GeminiWebSession? {
        guard let base = googleSession ?? (try? authStore.loadSession(source: source)) else { return nil }
        let hostCookies = (try? authStore.loadCookies(source: source, host: host, names: [Self.flowOSIDCookieName])) ?? [:]
        guard let secureOSID = hostCookies[Self.flowOSIDCookieName],
              !base.cookieHeader.contains("\(Self.flowOSIDCookieName)=") else {
            return base
        }
        return GeminiWebSession(cookieHeader: base.cookieHeader + "; \(Self.flowOSIDCookieName)=\(secureOSID)")
    }

    private func fetchWizBatch<Parsed>(
        host: String,
        endpointName: String,
        session: GeminiWebSession,
        http: any HTTPClient,
        makeRequest: (GeminiWebSession, String) -> HTTPRequest,
        parse: (HTTPResponse) -> Parsed?
    ) async -> (parsed: Parsed?, warnings: [ProviderDiagnosticWarning]) {
        let fingerprint = Data(SHA256.hash(data: Data(session.cookieHeader.utf8)))
        do {
            for attempt in 0..<2 {
                let token: String
                let usedCachedToken: Bool
                if attempt == 0, let cached = cachedPageTokens[host], cached.fingerprint == fingerprint {
                    token = cached.token
                    usedCachedToken = true
                } else {
                    cachedPageTokens[host] = nil
                    token = try await fetchPageToken(host: host, endpointName: endpointName, session: session, http: http)
                    cachedPageTokens[host] = (fingerprint, token)
                    usedCachedToken = false
                }
                let response = try await http.send(makeRequest(session, token))
                let parsed = parse(response)
                // A stale `at` token may fail with 400/401 or a 200 error/null payload; refetch once when cached.
                if attempt == 0, ([400, 401].contains(response.statusCode) || (usedCachedToken && parsed == nil)) {
                    cachedPageTokens[host] = nil
                    continue
                }
                if let parsed {
                    let warnings = ResponseSchemaWatch.httpHeaders(response, provider: .gemini, endpoint: endpointName)
                    return (parsed, warnings)
                }
                cachedPageTokens[host] = nil
                return (nil, [])
            }
            cachedPageTokens[host] = nil
            return (nil, [])
        } catch {
            cachedPageTokens[host] = nil
            return (nil, [])
        }
    }

    private func fetchPageToken(host: String, endpointName: String, session: GeminiWebSession, http: any HTTPClient) async throws -> String {
        let response = try await http.send(HTTPRequest(method: .get, url: URL(string: "https://\(host)/")!, headers: [
            "Accept": "text/html",
            "Cookie": session.cookieHeader
        ]))
        guard response.statusCode == 200, let token = Self.pageToken(in: response.body) else {
            throw ProviderFailure(.authentication, "\(endpointName) session is unavailable.")
        }
        return token
    }

    private static func wizBatchRequest(
        host: String,
        path: String,
        rpc: String,
        session: GeminiWebSession,
        token: String,
        includeSameDomain: Bool
    ) -> HTTPRequest {
        var url = URLComponents(string: "https://\(host)\(path)")!
        url.queryItems = [URLQueryItem(name: "rpcids", value: rpc), URLQueryItem(name: "source-path", value: "/"),
                          URLQueryItem(name: "hl", value: "en"), URLQueryItem(name: "rt", value: "c")]
        let request = #"[[["\#(rpc)","[]",null,"generic"]]]"#
        let body = "f.req=\(formEncoded(request))&at=\(formEncoded(token))"
        var headers = [
            "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
            "Origin": "https://\(host)",
            "Referer": "https://\(host)/",
            "Cookie": session.cookieHeader
        ]
        if includeSameDomain {
            headers["X-Same-Domain"] = "1"
        }
        return HTTPRequest(method: .post, url: url.url!, headers: headers, body: Data(body.utf8))
    }

    // MARK: Google Flow

    struct ParsedFlow: Equatable, Sendable {
        let balance: Double
        let resetsAt: Date?
    }

    private func flowDetails(session: GeminiWebSession) async -> (reading: MediaCreditReading, warnings: [ProviderDiagnosticWarning]) {
        let now = dateProvider.now()
        let result = await fetchWizBatch(
            host: Self.flowHost,
            endpointName: "Gemini Flow",
            session: session,
            http: flowHTTP,
            makeRequest: { Self.flowRequest(session: $0, token: $1) },
            parse: { Self.parseFlow(response: $0, now: now) }
        )
        guard let parsed = result.parsed else { return (.unavailable(status: "N/A"), []) }
        return (.available(balance: parsed.balance, resetsAt: parsed.resetsAt), result.warnings)
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
        wizBatchRequest(host: flowHost, path: flowBatchPath, rpc: flowRPC, session: session, token: token, includeSameDomain: false)
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

    // MARK: Google Stitch

    struct ParsedStitch: Equatable, Sendable {
        let used: Double
        let limit: Double
    }

    private func stitchDetails(session: GeminiWebSession) async -> (reading: BoundedCountReading, warnings: [ProviderDiagnosticWarning]) {
        let result = await fetchWizBatch(
            host: Self.stitchHost,
            endpointName: "Gemini Stitch",
            session: session,
            http: stitchHTTP,
            makeRequest: { Self.stitchRequest(session: $0, token: $1) },
            parse: { Self.parseStitch(response: $0) }
        )
        guard let parsed = result.parsed else { return (.unavailable(status: "N/A"), []) }
        return (.available(used: parsed.used, limit: parsed.limit, resetsAt: nil), result.warnings)
    }

    static func stitchRequest(session: GeminiWebSession, token: String) -> HTTPRequest {
        wizBatchRequest(host: stitchHost, path: stitchBatchPath, rpc: stitchRPC, session: session, token: token, includeSameDomain: true)
    }

    static func parseStitch(response: HTTPResponse) -> ParsedStitch? {
        guard response.statusCode == 200,
              let payload = batchPayload(rpc: stitchRPC, in: response.body),
              let values = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [Any],
              values.count > 9,
              let limit = QuotaDiscovery.number(values[9]), limit.isFinite, limit > 0 else {
            return nil
        }
        let used: Double
        if values[8] is NSNull {
            used = 0
        } else if let parsedUsed = QuotaDiscovery.number(values[8]), parsedUsed.isFinite, parsedUsed >= 0 {
            used = parsedUsed
        } else {
            return nil
        }
        return ParsedStitch(used: used, limit: limit)
    }

    // MARK: NotebookLM

    struct ParsedNotebookLM: Equatable, Sendable {
        let session: PercentQuotaReading?
        let weekly: PercentQuotaReading?
    }

    private func notebookLMDetails(session: GeminiWebSession) async -> (session: PercentQuotaReading, weekly: PercentQuotaReading, warnings: [ProviderDiagnosticWarning]) {
        let now = dateProvider.now()
        let result = await fetchWizBatch(
            host: Self.notebookLMHost,
            endpointName: "Gemini NotebookLM",
            session: session,
            http: notebookLMHTTP,
            makeRequest: { Self.notebookLMRequest(session: $0, token: $1) },
            parse: { Self.parseNotebookLM(response: $0, now: now) }
        )
        guard let parsed = result.parsed else {
            return (.unavailable(status: "N/A"), .unavailable(status: "N/A"), [])
        }
        return (
            parsed.session ?? .unavailable(status: "N/A"),
            parsed.weekly ?? .unavailable(status: "N/A"),
            result.warnings
        )
    }

    static func notebookLMRequest(session: GeminiWebSession, token: String) -> HTTPRequest {
        wizBatchRequest(host: notebookLMHost, path: notebookLMBatchPath, rpc: notebookLMRPC, session: session, token: token, includeSameDomain: true)
    }

    static func parseNotebookLM(response: HTTPResponse, now: Date) -> ParsedNotebookLM? {
        guard response.statusCode == 200,
              let payload = batchPayload(rpc: notebookLMRPC, in: response.body),
              let values = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [Any],
              values.count > 1,
              let pools = values[1] as? [Any] else {
            return nil
        }
        var sessionReading: PercentQuotaReading?
        var weeklyReading: PercentQuotaReading?
        for case let pool as [Any] in pools where pool.count > 7 {
            guard let poolTypeValue = QuotaDiscovery.number(pool[4]), poolTypeValue.isFinite else { continue }
            let poolType = Int(poolTypeValue)
            guard poolType == 1 || poolType == 2 else { continue }
            var resetsAt: Date?
            if let stamp = pool[5] as? [Any], let seconds = QuotaDiscovery.number(stamp.first), seconds.isFinite, seconds > 0 {
                let candidate = Date(timeIntervalSince1970: seconds)
                if candidate > now {
                    resetsAt = candidate
                }
            }
            let remainingPct: Double
            if pool[7] is NSNull {
                guard resetsAt != nil else { continue }
                remainingPct = 0
            } else if let parsedRemaining = QuotaDiscovery.number(pool[7]),
                      parsedRemaining.isFinite,
                      (0...100).contains(parsedRemaining) {
                remainingPct = parsedRemaining
            } else {
                continue
            }
            let reading = PercentQuotaReading.available(usedPercent: min(max(100 - remainingPct, 0), 100), resetsAt: resetsAt)
            if poolType == 1, sessionReading == nil {
                sessionReading = reading
            } else if poolType == 2, weeklyReading == nil {
                weeklyReading = reading
            }
        }
        guard sessionReading != nil || weeklyReading != nil else { return nil }
        return ParsedNotebookLM(session: sessionReading, weekly: weeklyReading)
    }
}
