import CryptoKit
import Foundation

/// Reads only the native app's OAuth record; never falls back to Gemini or CLI accounts.
struct AntigravityDesktopCredentials: Sendable {
    struct Credential: Sendable {
        let refresh: String
        let email: String?
        var fingerprint: Data { Data(SHA256.hash(data: Data(refresh.utf8))) }
        var historyID: String { "native-session:" + fingerprint.map { String(format: "%02x", $0) }.joined() }
    }
    static let roots = ["~/Library/Application Support/Antigravity IDE", "~/Library/Application Support/Antigravity"]
    let sqlite: any SQLiteValueReading
    let exists: @Sendable (String) -> Bool
    init(sqlite: any SQLiteValueReading = ReadOnlySessionSQLiteReader(),
         exists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: expandHome($0)) }) {
        self.sqlite = sqlite; self.exists = exists
    }
    func load() throws -> Credential {
        // Prefer the installed IDE's own profile. A missing/invalid login in that
        // profile must not silently select a different account in the old app.
        guard let root = Self.roots.first(where: { exists($0 + "/User/globalStorage/state.vscdb") }) else {
            throw ProviderFailure(.authentication, "Sign in to Antigravity desktop.")
        }
        let path = root + "/User/globalStorage/state.vscdb"
        guard let raw = try sqlite.queryValue(path: path,
            sql: "SELECT value FROM ItemTable WHERE key='antigravityUnifiedStateSync.oauthToken'"),
              let refresh = Self.refreshToken(raw) else {
            throw ProviderFailure(.authentication, "Antigravity desktop login is missing or changed. Sign in again.")
        }
        let identity = try sqlite.queryValue(path: path, sql: "SELECT value FROM ItemTable WHERE key='antigravityAuthStatus'")
        let status = identity.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let unified = try sqlite.queryValue(path: path, sql: "SELECT value FROM ItemTable WHERE key='antigravityUnifiedStateSync.userStatus'")
        let currentEmail = unified.flatMap(Self.email)
        let legacyEmail = AccountEmail.validated(status?["email"])
        // Conflicting native identity caches must not label the token as another account.
        let email = currentEmail != nil && legacyEmail != nil && currentEmail?.lowercased() != legacyEmail?.lowercased()
            ? nil : currentEmail ?? legacyEmail
        return Credential(refresh: refresh, email: email)
    }
    static func refreshToken(_ raw: String) -> String? {
        guard let auth = payload(raw, sentinel: "oauthTokenInfoSentinelKey"),
              let fields = try? GeminiProtobuf.fields(auth),
              let token = fields.first(where: { $0.number == 3 })?.bytes,
              let value = String(data: token, encoding: .utf8), !value.isEmpty,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return value
    }
    static func email(_ raw: String) -> String? {
        guard let data = payload(raw, sentinel: "userStatusSentinelKey"),
              let fields = try? GeminiProtobuf.fields(data),
              let bytes = fields.first(where: { $0.number == 7 })?.bytes,
              let email = String(data: bytes, encoding: .utf8) else { return nil }
        return AccountEmail.validated(email)
    }
    private static func payload(_ raw: String, sentinel: String) -> Data? {
        guard raw.utf8.count <= 4_194_304, let data = Data(base64Encoded: raw),
              let outer = try? GeminiProtobuf.fields(data) else { return nil }
        var matches: [Data] = []
        for item in outer where item.number == 1 {
            guard let bytes = item.bytes, let entry = try? GeminiProtobuf.fields(bytes),
                  entry.first(where: { $0.number == 1 })?.bytes == Data(sentinel.utf8),
                  let wrapper = entry.first(where: { $0.number == 2 })?.bytes,
                  let fields = try? GeminiProtobuf.fields(wrapper),
                  let encoded = fields.first(where: { $0.number == 1 })?.bytes,
                  let payload = Data(base64Encoded: encoded) else { continue }
            matches.append(payload)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

actor AntigravityDesktopProvider: UsageProvider {
    nonisolated let id = ProviderID.antigravity
    private let credentials: AntigravityDesktopCredentials
    private let client: AntigravityUsageClient
    private let now: @Sendable () -> Date
    private var access: (fingerprint: Data, token: String, expires: Date)?
    private var metadata: (fingerprint: Data, plan: String?, project: String?, creditsDetail: ProviderUsageDetail?, codeAssistWarnings: [ProviderDiagnosticWarning], checked: Date)?
    init(credentials: AntigravityDesktopCredentials = AntigravityDesktopCredentials(),
         client: AntigravityUsageClient = AntigravityUsageClient(http: GeminiReadOnlyHTTPClient(
            allowedHosts: ["oauth2.googleapis.com", "daily-cloudcode-pa.googleapis.com"])),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials; self.client = client; self.now = now
    }
    func fetch() async throws -> ProviderSnapshot {
        let credential: AntigravityDesktopCredentials.Credential
        do { credential = try credentials.load() }
        catch { access = nil; metadata = nil; throw error }
        if access?.fingerprint != credential.fingerprint { access = nil; metadata = nil }
        for attempt in 0...1 {
            if access == nil || access!.expires.timeIntervalSince(now()) <= 60 {
                switch await client.refresh(credential.refresh) {
                case let .refreshed(token, seconds):
                    access = (credential.fingerprint, token, now().addingTimeInterval(seconds))
                case .rejected: throw ProviderFailure(.authentication, "Antigravity login expired. Sign in to Antigravity again.")
                case .unavailable: throw ProviderFailure(.transient, "Antigravity login could not be refreshed.")
                }
            }
            let token = access!.token
            if metadata == nil || now().timeIntervalSince(metadata!.checked) >= 3600 {
                switch await client.loadCodeAssist(accessToken: token) {
                case let .success(data, headers):
                    metadata = (
                        credential.fingerprint,
                        AntigravityUsageMapper.plan(data),
                        AntigravityUsageMapper.project(data),
                        AntigravityUsageMapper.aiCreditsDetail(data),
                        AntigravityUsageMapper.codeAssistWarnings(data, headers: headers),
                        now()
                    )
                case .tokenRefused: access = nil; if attempt == 0 { continue }
                case .denied, .unavailable: break
                }
            }
            let response = await client.quotaSummary(accessToken: token, project: metadata?.project, now: now())
            guard try credentials.load().fingerprint == credential.fingerprint else {
                access = nil; metadata = nil
                throw ProviderFailure(.transient, "Antigravity account changed. Refresh again.")
            }
            try Task.checkCancellation()
            switch response {
            case let .success(summaries):
                let extraDetails = metadata?.creditsDetail.map { [$0] } ?? []
                let extraWarnings = metadata?.codeAssistWarnings ?? []
                guard let value = AntigravityUsageMapper.summary(
                    summaries,
                    planName: metadata?.plan,
                    now: now(),
                    extraDetails: extraDetails,
                    extraWarnings: extraWarnings
                ), !value.windows.isEmpty else {
                    throw ProviderFailure(.invalidResponse, "Antigravity quota response changed.")
                }
                return value.withCredential(source: "Antigravity app", account: credential.email ?? credential.historyID, email: credential.email)
            case .tokenRefused: access = nil; if attempt == 0 { continue }
            case .denied: throw ProviderFailure(.authentication, "Antigravity quota access was denied for its desktop account.")
            case let .rateLimited(retry): throw ProviderFailure(.rateLimited, "Antigravity quota is rate limited.", retryAt: retry)
            case .unavailable: throw ProviderFailure(.transient, "Antigravity quota could not be reached.")
            }
        }
        throw ProviderFailure(.authentication, "Sign in to Antigravity desktop again.")
    }
}
