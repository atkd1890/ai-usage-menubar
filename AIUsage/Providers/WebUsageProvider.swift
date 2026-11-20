import CryptoKit
import Foundation

/// A selected browser session is exclusive: never silently substitute local OAuth.
actor WebUsageProvider: UsageProvider {
    nonisolated let id: ProviderID
    private let source: WebSessionSource
    private let sessions: WebSessionStore
    private let http: any HTTPClient
    private let identity: AccountIdentityClient?
    private let identityCache: AccountIdentityCache
    private var claudeResetCache: (fingerprint: Data, org: String, checkedAt: Date, grants: ClaudeResetGrants?)?
    private var resetCache: (fingerprint: Data, account: String, checkedAt: Date, list: CodexResetCreditList?)?

    init(id: ProviderID, source: WebSessionSource, sessions: WebSessionStore = WebSessionStore(),
         http: (any HTTPClient)? = nil, identity: AccountIdentityClient? = nil) {
        self.id = id; self.source = source; self.sessions = sessions
        self.identityCache = AccountIdentityCache(provider: id, source: source.rawValue)
        self.identity = identity ?? (http == nil ? AccountIdentityClient() : nil)
        self.http = http ?? GeminiReadOnlyHTTPClient(allowedHosts: [id == .codex ? "chatgpt.com" : id == .claude ? "claude.ai" : "cursor.com"])
    }
    func fetch() async throws -> ProviderSnapshot {
        switch id {
        case .claude: try await claude()
        case .codex: try await codex()
        case .cursor: try await cursor()
        default: throw ProviderFailure(.authentication, "This provider has no verified browser usage adapter.")
        }
    }
    private var sourceLabel: String {
        switch source {
        case .edge: "Edge Default"
        case .chrome: "Chrome Default"
        case .claudeDesktop: "Claude desktop"
        case .codexDesktop: "Codex desktop"
        case .manusDesktop: "Manus desktop"
        }
    }
    private func request(_ url: String, cookie: String, token: String? = nil,
                         account: String? = nil, post: Bool = false) async throws -> HTTPResponse {
        var headers = ["Cookie": cookie, "Accept": "application/json"]
        if let token { headers["Authorization"] = "Bearer " + token }
        if let account { headers["ChatGPT-Account-ID"] = account }
        if url == CodexUsageClient.resetCreditsURL.absoluteString {
            headers["OpenAI-Beta"] = "codex-1"
            headers["originator"] = "Codex Desktop"
        }
        if post { headers["Content-Type"] = "application/json"; headers["Origin"] = "https://cursor.com" }
        return try await http.send(HTTPRequest(method: post ? .post : .get, url: URL(string: url)!,
                                              headers: headers, body: post ? Data("{}".utf8) : nil))
    }
    private func validate(_ response: HTTPResponse) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401, 403, 300..<400:
            throw ProviderFailure(.authentication, "The selected \(sourceLabel) session was rejected (HTTP \(response.statusCode)). Sign in again; browser verification may be required.")
        case 429: throw ProviderFailure(.rateLimited, "The selected browser session is rate limited.")
        default: throw ProviderFailure(.transient, "Usage request failed (HTTP \(response.statusCode)).")
        }
    }
    private func claude() async throws -> ProviderSnapshot {
        let cookie = try sessions.cookies(source: source, domain: "claude.ai",
            names: ["sessionKey", "sessionKeyLC", "sessionKeyV3", "sessionKeyV3LC"])
        let response = try await request("https://claude.ai/api/organizations", cookie: cookie)
        try validate(response)
        guard let organizations = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
            throw ProviderFailure(.invalidResponse, "Claude organization response changed.")
        }
        // Console/API organizations have a different budget and must never supply Chat/Code quota.
        let chat = organizations.filter { ($0["capabilities"] as? [String])?.contains("chat") == true }
        guard chat.count == 1, let org = chat.first,
              let orgID = ProviderParsing.string(org["uuid"]), UUID(uuidString: orgID) != nil else {
            throw ProviderFailure(.authentication, chat.count > 1
                ? "This session has multiple Claude Chat organizations; explicit organization selection is required."
                : "The selected session has no Claude Chat organization.")
        }
        let now = Date()
        let fingerprint = Data(SHA256.hash(data: Data(cookie.utf8)))
        let cache = claudeResetCache
        let includeGrants = cache == nil || cache?.fingerprint != fingerprint || cache?.org != orgID ||
            now.timeIntervalSince(cache!.checkedAt) >= 3600
        let base = "https://claude.ai/api/organizations/\(orgID)/usage"
        var usage = try await request(base + (includeGrants ? "?cedar_ember=1" : ""), cookie: cookie)
        if includeGrants && usage.statusCode == 429 { usage = try await request(base, cookie: cookie) }
        try validate(usage)
        let body = try ProviderParsing.object(from: usage.body)
        var grants = cache?.fingerprint == fingerprint && cache?.org == orgID ? cache?.grants : nil
        if includeGrants {
            grants = ClaudeResetGrants.parse(body["cedar_ember"]) ?? grants
            claudeResetCache = (fingerprint, orgID, now, grants)
        }
        let rawPlan = ProviderParsing.string(org["analytics_subscription_plan"])?
            .split(separator: " ").first.map(String.init)
        let credentials = ClaudeOAuth(subscriptionType: rawPlan,
                                      rateLimitTier: ProviderParsing.string(org["rate_limit_tier"]))
        let value = try ClaudeUsageMapper.map(response: usage, credentials: credentials,
                                             resets: grants?.resets(at: now), now: now)
        guard !value.windows.isEmpty else { throw ProviderFailure(.invalidResponse, "The selected session returned no Claude quota.") }
        var email: String?
        if let identity { email = await identityCache.read(credential: cookie) { try await identity.claudeWeb(cookie) } }
        return value.withCredential(source: sourceLabel, account: email, email: email)
    }
    private func codex() async throws -> ProviderSnapshot {
        let cookie = try sessions.cookies(source: source, domain: "chatgpt.com", names: [
            "__Secure-next-auth.session-token", "__Secure-next-auth.session-token.0", "__Secure-next-auth.session-token.1"])
        let session = try await request("https://chatgpt.com/api/auth/session", cookie: cookie)
        try validate(session)
        let identity = try ProviderParsing.object(from: session.body)
        guard let token = ProviderParsing.string(identity["accessToken"]), !token.isEmpty else {
            throw ProviderFailure(.authentication, "Sign in to ChatGPT in \(sourceLabel).")
        }
        let usage = try await request(CodexUsageClient.usageURL.absoluteString, cookie: cookie, token: token)
        try validate(usage)
        let body = try ProviderParsing.object(from: usage.body)
        let email = ProviderParsing.string(body["email"])
        let sessionEmail = ProviderParsing.object(identity["user"]).flatMap { ProviderParsing.string($0["email"]) }
        if let email, let sessionEmail, email.lowercased() != sessionEmail.lowercased() {
            throw ProviderFailure(.authentication, "The browser session and Codex usage belong to different accounts.")
        }
        let now = Date()
        let account = ProviderParsing.string(body["account_id"])
        let fingerprint = Data(SHA256.hash(data: Data(cookie.utf8)))
        var resetList: CodexResetCreditList?
        if let account {
            if let cache = resetCache, cache.fingerprint == fingerprint, cache.account == account,
               now.timeIntervalSince(cache.checkedAt) < 3600 { resetList = cache.list }
            else {
                if let response = try? await request(CodexUsageClient.resetCreditsURL.absoluteString,
                                                     cookie: cookie, token: token, account: account), response.statusCode == 200 {
                    resetList = CodexResetCreditList.parse(response.body, headers: response.headers)
                }
                resetCache = (fingerprint, account, now, resetList)
            }
        }
        let value = try CodexUsageMapper.map(response: usage, resetCreditList: resetList, now: now)
        guard !value.windows.isEmpty else { throw ProviderFailure(.invalidResponse, "The selected session returned no Codex quota.") }
        return value.withCredential(source: sourceLabel, account: email ?? sessionEmail, email: email ?? sessionEmail)
    }
    private func cursor() async throws -> ProviderSnapshot {
        let cookie = try sessions.cookies(source: source, domain: "cursor.com", names: ["WorkosCursorSessionToken"])
        let usage = try await request("https://cursor.com/api/dashboard/v2/usage-status?scope=user", cookie: cookie)
        try validate(usage)
        let body = try ProviderParsing.object(from: usage.body)
        // This endpoint's weekly pool is the unified X subscription, never legacy monthly Cursor usage.
        guard ProviderParsing.object(body["weeklyIncludedUsage"]) != nil else {
            throw ProviderFailure(.invalidResponse, "This browser account has no unified X weekly usage.")
        }
        let shared = try? await request("https://cursor.com/api/dashboard/get-sand-usage-status", cookie: cookie, post: true)
        let plan = shared.flatMap { try? ProviderParsing.object(from: $0.body) }
            .flatMap { ProviderParsing.string($0["grokPlanLabel"]) ?? ProviderParsing.string($0["cursorPlanName"]) }
        let legacy = ProviderSnapshot(provider: .cursor, planName: plan, windows: [], fetchedAt: Date())
        let value = try CursorUnifiedUsageMapper.map(legacy: legacy, dashboard: usage, shared: shared,
                                                     isMerged: true, now: Date())
        var email: String?
        if let identity { email = await identityCache.read(credential: cookie) { try await identity.cursor(cookie) } }
        return value.withCredential(source: sourceLabel, account: email, email: email)
    }
}

actor CredentialSelectingProvider: UsageProvider {
    nonisolated let id: ProviderID
    private let local: any UsageProvider
    private let edge: any UsageProvider
    private let chrome: any UsageProvider
    private let desktop: (any UsageProvider)?
    private let method: @Sendable () -> ProviderLoginMethod
    init(local: any UsageProvider, method: (@Sendable () -> ProviderLoginMethod)? = nil,
         edge: (any UsageProvider)? = nil, chrome: (any UsageProvider)? = nil) {
        let id = local.id
        self.id = id; self.local = local
        self.edge = edge ?? WebUsageProvider(id: id, source: .edge)
        self.chrome = chrome ?? WebUsageProvider(id: id, source: .chrome)
        self.desktop = id == .claude ? WebUsageProvider(id: id, source: .claudeDesktop) : nil
        self.method = method ?? { ProviderLoginMethod.selected(for: id) }
    }
    func fetch() async throws -> ProviderSnapshot {
        switch method() {
        case .edge: return try await edge.fetch()
        case .chrome: return try await chrome.fetch()
        case .desktop where id == .claude:
            guard let desktop else { throw ProviderFailure(.storage, "Claude desktop adapter is unavailable.") }
            return try await desktop.fetch()
        default: return try await local.fetch()
        }
    }
}

extension ProviderSnapshot {
    func withCredential(source: String, account: String?, email: String? = nil) -> Self {
        Self(provider: provider, planName: planName, windows: windows, billingUsage: billingUsage,
             resets: resets, fetchedAt: fetchedAt, xSubscription: xSubscription,
             credentialSource: source, accountLabel: account ?? accountLabel,
             accountEmail: email ?? accountEmail, usageScope: usageScope,
             usageDetails: usageDetails, prepaidBalance: prepaidBalance,
             additionalUsageEnabled: additionalUsageEnabled,
             additionalUsageResetsAt: additionalUsageResetsAt,
             usageBreakdown: usageBreakdown,
             quotaSections: quotaSections,
             diagnosticWarnings: diagnosticWarnings)
    }
}
