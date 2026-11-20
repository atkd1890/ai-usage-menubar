import CryptoKit
import Foundation

struct QwenCredential: Sendable {
    let access: String?
    let refresh: String?
    let sourceLabel: String

    var fingerprint: Data {
        Data(SHA256.hash(data: Data((sourceLabel + "\0" + (refresh ?? access ?? "")).utf8)))
    }

    var fingerprintHex: String {
        fingerprint.map { String(format: "%02x", $0) }.joined()
    }

    var historyID: String {
        "qwen-session:" + fingerprintHex
    }

    static func valid(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(where: { $0.isWhitespace || $0 == ";" || $0 == "\"" || $0 == "\\" })
    }

    static func jwtExpiration(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let data = ProviderParsing.base64URLData(String(parts[1])),
              let object = try? ProviderParsing.object(from: data),
              let exp = QuotaDiscovery.number(object["exp"]) else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }
}

struct QwenPersistedSession: Codable, Equatable, Sendable {
    var seedFingerprint: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var email: String?
    var isForked: Bool
}

struct QwenSessionStore: Sendable {
    static let defaultPath = "~/Library/Application Support/AI Usage/qwen-auth.json"

    let files: any TextFileAccessing
    let path: String

    init(
        files: any TextFileAccessing = LocalTextFileAccessor(),
        path: String = Self.defaultPath
    ) {
        self.files = files
        self.path = path
    }

    func load(for sourceLabel: String) -> QwenPersistedSession? {
        loadAll()[sourceLabel]
    }

    func save(_ session: QwenPersistedSession, for sourceLabel: String) {
        var all = loadAll()
        all[sourceLabel] = session
        writeAll(all)
    }

    func remove(for sourceLabel: String) {
        var all = loadAll()
        guard all.removeValue(forKey: sourceLabel) != nil else { return }
        writeAll(all)
    }

    private func loadAll() -> [String: QwenPersistedSession] {
        guard files.exists(path),
              let text = try? files.readText(path),
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: QwenPersistedSession].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func writeAll(_ sessions: [String: QwenPersistedSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? files.writeText(path, String(decoding: data, as: UTF8.self))
    }
}

enum QwenNativeSession {
    static let desktopLocalStoragePath = "~/Library/Application Support/Qwen/Local Storage/leveldb"
    static let desktopCookiesPath = "~/Library/Application Support/Qwen/Cookies"
    static let edgeLocalStoragePath = "~/Library/Application Support/Microsoft Edge/Default/Local Storage/leveldb"
    static let chromeLocalStoragePath = "~/Library/Application Support/Google/Chrome/Default/Local Storage/leveldb"
    static let origin = "https://chat.qwen.ai"

    static func sourceLabel(for method: ProviderLoginMethod) -> String {
        switch method {
        case .edge: "Edge Default"
        case .chrome: "Chrome Default"
        default: "Qwen desktop"
        }
    }

    static func load(
        method: ProviderLoginMethod = ProviderLoginMethod.selected(for: .qwen),
        sessions: WebSessionStore = WebSessionStore(),
        sqlite: any SQLiteValueReading = ReadOnlySessionSQLiteReader(),
        files: any TextFileAccessing = LocalTextFileAccessor(),
        localStorageDirectory: String = desktopLocalStoragePath,
        desktopCookiesPath: String = desktopCookiesPath,
        browserLocalStorageDirectories: [ProviderLoginMethod: String]? = nil
    ) throws -> QwenCredential {
        switch method {
        case .edge, .chrome:
            let source: WebSessionSource = method == .edge ? .edge : .chrome
            let label = sourceLabel(for: method)
            let browserStoragePath = browserLocalStorageDirectories?[method]
                ?? (method == .edge ? edgeLocalStoragePath : chromeLocalStoragePath)

            var access: String?
            if browserLocalStorageDirectories != nil || QwenSessionStore(files: files).load(for: label) == nil,
               files.exists(browserStoragePath) {
                let directory = URL(fileURLWithPath: expandHome(browserStoragePath))
                if let values = try? ScopedLocalStorageReader().read(
                    directory: directory,
                    origin: origin,
                    names: ["qwen_access_token_state", "token"]
                ),
                let candidate = extractAccessToken(from: values),
                QwenCredential.jwtExpiration(candidate).map({ $0.timeIntervalSinceNow > 60 }) == true {
                    access = candidate
                }
            }

            var refresh: String?
            var cookieFailure: ProviderFailure?
            do {
                let cookieHeader = try sessions.cookies(source: source, domain: "qwen.ai", names: ["refresh_token"])
                if let value = cookieValue(named: "refresh_token", in: cookieHeader), QwenCredential.valid(value) {
                    refresh = value
                }
            } catch let failure as ProviderFailure {
                cookieFailure = failure
            } catch {
                cookieFailure = ProviderFailure(.storage, "Sign in to Qwen in \(label), then refresh.")
            }

            if access == nil && refresh == nil {
                if let cookieFailure {
                    throw cookieFailure
                }
                throw ProviderFailure(.authentication, "Sign in to Qwen in \(label), then refresh.")
            }
            return QwenCredential(access: access, refresh: refresh, sourceLabel: label)
        default:
            return try loadDesktop(
                sqlite: sqlite,
                files: files,
                localStorageDirectory: localStorageDirectory,
                cookiesPath: desktopCookiesPath
            )
        }
    }

    private static func loadDesktop(
        sqlite: any SQLiteValueReading,
        files: any TextFileAccessing,
        localStorageDirectory: String,
        cookiesPath: String
    ) throws -> QwenCredential {
        var access: String?
        if files.exists(localStorageDirectory) {
            let directory = URL(fileURLWithPath: expandHome(localStorageDirectory))
            if let values = try? ScopedLocalStorageReader().read(
                directory: directory,
                origin: origin,
                names: ["qwen_access_token_state", "token"]
            ) {
                access = extractAccessToken(from: values)
            }
        }

        var refresh: String?
        var storageError: ProviderFailure?
        if files.exists(cookiesPath) {
            do {
                if let raw = try sqlite.queryValue(
                    path: cookiesPath,
                    sql: "SELECT value FROM cookies WHERE host_key IN ('qwen.ai', '.qwen.ai') AND name='refresh_token' LIMIT 1"
                ) {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if QwenCredential.valid(trimmed) {
                        refresh = trimmed
                    }
                }
            } catch let failure as ProviderFailure {
                storageError = failure
            } catch {
                storageError = ProviderFailure(.storage, "Qwen desktop session storage is unavailable.")
            }
        }

        if access == nil && refresh == nil {
            if let storageError {
                throw storageError
            }
            throw ProviderFailure(.authentication, "Sign in to Qwen desktop (chat.qwen.ai), then refresh.")
        }

        return QwenCredential(access: access, refresh: refresh, sourceLabel: "Qwen desktop")
    }

    static func extractAccessToken(from values: [String: String]) -> String? {
        if let stateRaw = values["qwen_access_token_state"],
           let stateData = stateRaw.data(using: .utf8),
           let stateObject = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any],
           let token = stateObject["token"] as? String,
           QwenCredential.valid(token) {
            return token
        }
        if let tokenRaw = values["token"] {
            if let data = tokenRaw.data(using: .utf8),
               let jsonString = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String,
               QwenCredential.valid(jsonString) {
                return jsonString
            }
            if QwenCredential.valid(tokenRaw) {
                return tokenRaw
            }
        }
        return nil
    }

    private static func cookieValue(named name: String, in header: String) -> String? {
        let prefix = name + "="
        for part in header.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
        }
        return nil
    }
}

actor QwenProvider: UsageProvider {
    nonisolated let id = ProviderID.qwen

    static let allowedHosts: Set<String> = [
        "auth.qwen.ai",
        "chat.qwen.ai",
        "sg-entitlement.qwen.com",
        "sg-member.qwen.com"
    ]
    private static let query = "biz_id=ai_qwen&chat_client=h5&device=pc&fr=pc&pr=qwen-i18n&la=en-US&tz=UTC&wv=0.3.46"
    static let refreshURL = URL(string: "https://auth.qwen.ai/api/v2/auths/refresh")!
    static let authorizeCodeURL = URL(string: "https://auth.qwen.ai/api/v2/auths/authorize/code")!
    static let authProfileURL = URL(string: "https://chat.qwen.ai/api/v2/auths")!
    static let agentUsageURL = URL(string: "https://sg-entitlement.qwen.com/api/entitlement/agent/usage?\(query)")!
    static let creditsURL = URL(string: "https://sg-entitlement.qwen.com/api/entitlement/credits/query?\(query)")!
    static let resetCardURL = URL(string: "https://sg-entitlement.qwen.com/api/entitlement/reset_card/remain?\(query)")!
    static let memberLevelURL = URL(string: "https://sg-member.qwen.com/api/member/level/query?\(query)")!

    static func refreshWithCodeURL(_ code: String) -> URL? {
        var components = URLComponents(url: refreshURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "code", value: code)]
        return components?.url
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

    private let http: any HTTPClient
    private let sessionStore: QwenSessionStore?
    private let loadCredentials: @Sendable () throws -> QwenCredential
    private let now: @Sendable () -> Date

    private var cache: [String: QwenPersistedSession] = [:]

    init(
        http: (any HTTPClient)? = nil,
        sessionStore: QwenSessionStore? = nil,
        loadCredentials: @escaping @Sendable () throws -> QwenCredential = {
            try QwenNativeSession.load()
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http ?? GeminiReadOnlyHTTPClient(allowedHosts: Self.allowedHosts)
        self.sessionStore = sessionStore ?? (http == nil ? QwenSessionStore() : nil)
        self.loadCredentials = loadCredentials
        self.now = now
    }

    func fetch() async throws -> ProviderSnapshot {
        let loader = loadCredentials
        let loadedCredential: QwenCredential?
        let loadAuthFailure: ProviderFailure?
        do {
            loadedCredential = try await Task.detached(priority: .utility) { try loader() }.value
            loadAuthFailure = nil
        } catch let failure as ProviderFailure where failure.kind == .authentication {
            loadedCredential = nil
            loadAuthFailure = failure
        }

        let sourceLabel: String
        let seedFingerprint: String
        let historyID: String
        var persisted: QwenPersistedSession?

        if let credential = loadedCredential {
            sourceLabel = credential.sourceLabel
            seedFingerprint = credential.fingerprintHex
            historyID = credential.historyID
            if let existing = cache[sourceLabel] ?? sessionStore?.load(for: sourceLabel) {
                cache[sourceLabel] = existing
                persisted = existing
            }
        } else {
            let fallbackLabel = QwenNativeSession.sourceLabel(for: ProviderLoginMethod.selected(for: .qwen))
            guard let existing = cache[fallbackLabel] ?? sessionStore?.load(for: fallbackLabel) else {
                throw loadAuthFailure!
            }
            cache[fallbackLabel] = existing
            persisted = existing
            sourceLabel = fallbackLabel
            seedFingerprint = existing.seedFingerprint
            historyID = "qwen-session:" + existing.seedFingerprint
        }

        var access = ""
        var email: String?
        var needsFork = false

        if let current = persisted {
            if current.expiresAt.timeIntervalSince(now()) > 60 {
                access = current.accessToken
                email = current.email
                needsFork = (current.refreshToken == nil)
            } else if let persistedRefresh = current.refreshToken {
                do {
                    let refreshed = try await refreshAccess(
                        refreshToken: persistedRefresh,
                        seedFingerprint: current.seedFingerprint,
                        sourceLabel: sourceLabel,
                        existingEmail: current.email,
                        isForked: current.isForked
                    )
                    persisted = refreshed
                    access = refreshed.accessToken
                    email = refreshed.email
                    needsFork = false
                } catch let failure as ProviderFailure where failure.kind == .authentication {
                    clearPersistedSession(for: sourceLabel)
                    persisted = nil
                    if let credential = loadedCredential {
                        if let localAccess = credential.access,
                           localAccess != current.accessToken,
                           QwenCredential.jwtExpiration(localAccess).map({ $0.timeIntervalSince(now()) > 60 }) ?? true {
                            access = localAccess
                            email = nil
                            needsFork = (QwenCredential.jwtExpiration(localAccess) != nil)
                        } else if let diskRefresh = credential.refresh,
                                  diskRefresh != persistedRefresh,
                                  credential.fingerprintHex != current.seedFingerprint {
                            let refreshed = try await refreshAccess(
                                refreshToken: diskRefresh,
                                seedFingerprint: credential.fingerprintHex,
                                sourceLabel: sourceLabel,
                                isForked: false
                            )
                            persisted = refreshed
                            access = refreshed.accessToken
                            email = refreshed.email
                            needsFork = false
                        } else {
                            throw failure
                        }
                    } else {
                        throw failure
                    }
                }
            } else {
                clearPersistedSession(for: sourceLabel)
                persisted = nil
            }
        }

        if persisted == nil && access.isEmpty {
            if let localAccess = loadedCredential?.access,
               QwenCredential.jwtExpiration(localAccess).map({ $0.timeIntervalSince(now()) > 60 }) ?? true {
                access = localAccess
                email = nil
                needsFork = (QwenCredential.jwtExpiration(localAccess) != nil)
            } else if let refresh = loadedCredential?.refresh {
                let refreshed = try await refreshAccess(
                    refreshToken: refresh,
                    seedFingerprint: seedFingerprint,
                    sourceLabel: sourceLabel,
                    isForked: false
                )
                persisted = refreshed
                access = refreshed.accessToken
                email = refreshed.email
                needsFork = false
            } else {
                throw loadAuthFailure ?? ProviderFailure(.authentication, "Qwen session expired. Sign in to \(sourceLabel) again.")
            }
        }

        for attempt in 0...1 {
            let agentUsage = try await send(url: Self.agentUsageURL, method: .get, token: access)
            if attempt == 0, Self.isAuthRejected(agentUsage) {
                if let activePersisted = persisted, let persistedRefresh = activePersisted.refreshToken {
                    do {
                        let refreshed = try await refreshAccess(
                            refreshToken: persistedRefresh,
                            seedFingerprint: activePersisted.seedFingerprint,
                            sourceLabel: sourceLabel,
                            existingEmail: email,
                            isForked: activePersisted.isForked
                        )
                        persisted = refreshed
                        access = refreshed.accessToken
                        email = refreshed.email ?? email
                        needsFork = false
                        continue
                    } catch let failure as ProviderFailure where failure.kind == .authentication {
                        clearPersistedSession(for: sourceLabel)
                        persisted = nil
                        if let credential = loadedCredential {
                            if let localAccess = credential.access,
                               localAccess != access,
                               QwenCredential.jwtExpiration(localAccess).map({ $0.timeIntervalSince(now()) > 60 }) ?? false {
                                access = localAccess
                                needsFork = true
                                continue
                            } else if let diskRefresh = credential.refresh,
                                      diskRefresh != persistedRefresh,
                                      credential.fingerprintHex != activePersisted.seedFingerprint {
                                let refreshed = try await refreshAccess(
                                    refreshToken: diskRefresh,
                                    seedFingerprint: credential.fingerprintHex,
                                    sourceLabel: sourceLabel,
                                    existingEmail: email,
                                    isForked: false
                                )
                                persisted = refreshed
                                access = refreshed.accessToken
                                email = refreshed.email ?? email
                                needsFork = false
                                continue
                            }
                        }
                        throw failure
                    }
                } else if let diskRefresh = loadedCredential?.refresh {
                    if persisted != nil {
                        clearPersistedSession(for: sourceLabel)
                        persisted = nil
                    }
                    let refreshed = try await refreshAccess(
                        refreshToken: diskRefresh,
                        seedFingerprint: seedFingerprint,
                        sourceLabel: sourceLabel,
                        existingEmail: email,
                        isForked: false
                    )
                    persisted = refreshed
                    access = refreshed.accessToken
                    email = refreshed.email ?? email
                    needsFork = false
                    continue
                }
            }

            try Self.validateSuccess(agentUsage, serviceName: "Qwen usage")

            let credits = try? await send(url: Self.creditsURL, method: .get, token: access)
            let resetCards = try? await send(url: Self.resetCardURL, method: .get, token: access)
            let memberLevel = try? await send(url: Self.memberLevelURL, method: .post, token: access, body: Data("{}".utf8))

            if email == nil, let profileResponse = try? await send(url: Self.authProfileURL, method: .get, token: access) {
                email = Self.extractEmail(from: profileResponse)
            }

            if needsFork {
                if let forked = await forkIndependentSession(
                    accessToken: access,
                    seedFingerprint: seedFingerprint,
                    sourceLabel: sourceLabel,
                    existingEmail: email
                ) {
                    email = forked.email ?? email
                } else if let exp = QwenCredential.jwtExpiration(access) {
                    let saved = QwenPersistedSession(
                        seedFingerprint: seedFingerprint,
                        accessToken: access,
                        refreshToken: nil,
                        expiresAt: exp,
                        email: email,
                        isForked: false
                    )
                    cache[sourceLabel] = saved
                    sessionStore?.save(saved, for: sourceLabel)
                }
            } else if let email, var existing = cache[sourceLabel], existing.email != email {
                existing.email = email
                cache[sourceLabel] = existing
                sessionStore?.save(existing, for: sourceLabel)
            }

            return try Self.map(
                agentUsage: agentUsage,
                credits: credits,
                resetCards: resetCards,
                memberLevel: memberLevel,
                email: email,
                sourceLabel: sourceLabel,
                historyID: historyID,
                now: now()
            )
        }

        throw ProviderFailure(.authentication, "Qwen session expired. Sign in to \(sourceLabel) again.")
    }

    private func clearPersistedSession(for sourceLabel: String) {
        cache.removeValue(forKey: sourceLabel)
        sessionStore?.remove(for: sourceLabel)
    }

    private func refreshAccess(
        refreshToken: String,
        seedFingerprint: String,
        sourceLabel: String,
        existingEmail: String? = nil,
        isForked: Bool = false
    ) async throws -> QwenPersistedSession {
        let response = try await http.send(HTTPRequest(
            method: .get,
            url: Self.refreshURL,
            headers: Self.refreshHeaders(cookie: "refresh_token=" + refreshToken),
            body: nil
        ))

        let parsed = try parseTokenResponse(response)
        let session = QwenPersistedSession(
            seedFingerprint: seedFingerprint,
            accessToken: parsed.access,
            refreshToken: parsed.refresh ?? refreshToken,
            expiresAt: parsed.expiresAt,
            email: parsed.email ?? existingEmail,
            isForked: isForked
        )
        cache[sourceLabel] = session
        sessionStore?.save(session, for: sourceLabel)
        return session
    }

    private func forkIndependentSession(
        accessToken: String,
        seedFingerprint: String,
        sourceLabel: String,
        existingEmail: String?
    ) async -> QwenPersistedSession? {
        guard let codeResponse = try? await http.send(HTTPRequest(
            method: .get,
            url: Self.authorizeCodeURL,
            headers: Self.refreshHeaders(authorization: "Bearer " + accessToken),
            body: nil
        )),
        codeResponse.statusCode == 200,
        let codeRoot = try? ProviderParsing.object(from: codeResponse.body),
        codeRoot["success"] as? Bool == true,
        let codeData = codeRoot["data"] as? [String: Any],
        let code = codeData["code"] as? String,
        !code.isEmpty,
        let exchangeURL = Self.refreshWithCodeURL(code) else {
            return nil
        }

        guard let exchangeResponse = try? await http.send(HTTPRequest(
            method: .get,
            url: exchangeURL,
            headers: Self.refreshHeaders(),
            body: nil
        )),
        let parsed = try? parseTokenResponse(exchangeResponse),
        let forkedRefresh = parsed.refresh else {
            return nil
        }

        let session = QwenPersistedSession(
            seedFingerprint: seedFingerprint,
            accessToken: parsed.access,
            refreshToken: forkedRefresh,
            expiresAt: parsed.expiresAt,
            email: parsed.email ?? existingEmail,
            isForked: true
        )
        cache[sourceLabel] = session
        sessionStore?.save(session, for: sourceLabel)
        return session
    }

    private func parseTokenResponse(
        _ response: HTTPResponse
    ) throws -> (access: String, refresh: String?, expiresAt: Date, email: String?) {
        if [401, 403].contains(response.statusCode) {
            throw ProviderFailure(.authentication, "Qwen session expired. Sign in again.")
        }
        guard response.statusCode == 200 else {
            throw ProviderFailure(
                response.statusCode == 429 ? .rateLimited : .transient,
                "Qwen session refresh failed (HTTP \(response.statusCode))."
            )
        }
        guard let root = try? ProviderParsing.object(from: response.body) else {
            throw ProviderFailure(.invalidResponse, "Qwen refresh response format changed.")
        }
        if root["success"] as? Bool == false {
            throw ProviderFailure(.authentication, "Qwen session expired. Sign in again.")
        }
        guard let data = root["data"] as? [String: Any],
              let access = data["access_token"] as? String,
              QwenCredential.valid(access) else {
            throw ProviderFailure(.invalidResponse, "Qwen refresh returned no valid access token.")
        }
        let rotatedRefresh = (data["refresh_token"] as? String).flatMap { QwenCredential.valid($0) ? $0 : nil }
            ?? Self.extractRefreshTokenCookie(from: response)
        let expiresAt = ProviderParsing.date(data["expires_at"])
            ?? QwenCredential.jwtExpiration(access)
            ?? now().addingTimeInterval(600)
        let email = AccountEmail.validated(data["email"])
        return (access, rotatedRefresh, expiresAt, email)
    }

    private static func refreshHeaders(
        cookie: String? = nil,
        authorization: String? = nil
    ) -> [String: String] {
        var headers = [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Version": "0.3.46",
            "source": "web",
            "X-Request-Id": UUID().uuidString,
            "Timezone": "GMT",
            "x-request-origin": QwenNativeSession.origin,
            "Origin": QwenNativeSession.origin,
            "Referer": QwenNativeSession.origin + "/",
            "User-Agent": userAgent
        ]
        if let cookie {
            headers["Cookie"] = cookie
        }
        if let authorization {
            headers["Authorization"] = authorization
        }
        return headers
    }

    static func extractRefreshTokenCookie(from response: HTTPResponse) -> String? {
        guard let setCookie = response.header("Set-Cookie") else { return nil }
        let pattern = #"(?:^|[,;\s])refresh_token=([^;\s,]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: setCookie, range: NSRange(setCookie.startIndex..., in: setCookie)),
              let range = Range(match.range(at: 1), in: setCookie) else {
            return nil
        }
        let value = String(setCookie[range])
        return QwenCredential.valid(value) ? value : nil
    }

    private func send(url: URL, method: HTTPRequest.Method, token: String, body: Data? = nil) async throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
            "Origin": QwenNativeSession.origin,
            "Referer": QwenNativeSession.origin + "/",
            "User-Agent": Self.userAgent
        ]
        if method == .post {
            headers["Content-Type"] = "application/json"
        }
        return try await http.send(HTTPRequest(method: method, url: url, headers: headers, body: body))
    }

    private static func isAuthRejected(_ response: HTTPResponse) -> Bool {
        if [401, 403].contains(response.statusCode) { return true }
        guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            return false
        }
        if let httpCode = QuotaDiscovery.number(root["httpCode"]), [401, 403].contains(Int(httpCode)) {
            return true
        }
        if root["success"] as? Bool == false {
            let errorCode = (root["errorCode"] as? String)
                ?? ((root["data"] as? [String: Any])?["code"] as? String)
            if let code = errorCode?.lowercased(),
               code.contains("unauthorized") || code.contains("token") || code.contains("auth") {
                return true
            }
        }
        return false
    }

    private static func validateSuccess(_ response: HTTPResponse, serviceName: String) throws {
        if [401, 403].contains(response.statusCode) {
            throw ProviderFailure(.authentication, "Qwen session rejected. Sign in again.")
        }
        if response.statusCode == 429 {
            throw ProviderFailure(.rateLimited, "Qwen usage is rate limited.")
        }
        guard response.statusCode == 200 else {
            throw ProviderFailure(.transient, "\(serviceName) request failed (HTTP \(response.statusCode)).")
        }
        guard let root = try? ProviderParsing.object(from: response.body),
              root["success"] as? Bool == true else {
            if isAuthRejected(response) {
                throw ProviderFailure(.authentication, "Qwen session rejected. Sign in again.")
            }
            throw ProviderFailure(.invalidResponse, "\(serviceName) response format changed.")
        }
    }

    private static func extractEmail(from response: HTTPResponse) -> String? {
        guard response.statusCode == 200,
              let root = try? ProviderParsing.object(from: response.body) else {
            return nil
        }
        if let data = root["data"] as? [String: Any], let email = AccountEmail.validated(data["email"]) {
            return email
        }
        return AccountEmail.validated(root["email"])
    }

    static func map(
        agentUsage: HTTPResponse,
        credits: HTTPResponse? = nil,
        resetCards: HTTPResponse? = nil,
        memberLevel: HTTPResponse? = nil,
        email: String? = nil,
        sourceLabel: String = "Qwen desktop",
        historyID: String? = nil,
        now: Date = Date()
    ) throws -> ProviderSnapshot {
        try validateSuccess(agentUsage, serviceName: "Qwen usage")
        guard let root = try? ProviderParsing.object(from: agentUsage.body),
              let data = root["data"] as? [String: Any],
              let remaining = QuotaDiscovery.number(data["remainingPercent"]),
              (0...100).contains(remaining) else {
            throw ProviderFailure(.invalidResponse, "Qwen returned invalid agent usage data.")
        }

        var warnings = ResponseSchemaWatch.httpHeaders(agentUsage, provider: .qwen, endpoint: "Qwen agent/usage")
        warnings += ResponseSchemaWatch.jsonBodyDeprecation(root, provider: .qwen, endpoint: "Qwen agent/usage")
        warnings += ResponseSchemaWatch.jsonBodyDeprecation(data, provider: .qwen, endpoint: "Qwen agent/usage")
        warnings += ResponseSchemaWatch.confirmedJSONKeys(in: data, provider: .qwen, endpoint: "Qwen agent/usage")

        var weeklyBalance: Double?
        var weeklyTotal: Double?
        var dailyWindow: QuotaWindow?
        var videoCreditsWindow: QuotaWindow?
        var imageGenerationWindow: QuotaWindow?
        var otherWindows: [QuotaWindow] = []
        var notices: [ProviderUsageDetail] = []

        if let credits {
            warnings += ResponseSchemaWatch.httpHeaders(credits, provider: .qwen, endpoint: "Qwen credits")
        }
        if let credits,
           credits.statusCode == 200,
           let creditsRoot = try? ProviderParsing.object(from: credits.body),
           creditsRoot["success"] as? Bool == true,
           let creditsData = creditsRoot["data"] as? [String: Any],
           let entitlements = creditsData["entitlements"] as? [[String: Any]] {
            warnings += ResponseSchemaWatch.jsonBodyDeprecation(creditsData, provider: .qwen, endpoint: "Qwen credits")
            warnings += ResponseSchemaWatch.confirmedJSONKeys(
                in: creditsData,
                provider: .qwen,
                endpoint: "Qwen credits"
            )
            for item in entitlements {
                warnings += ResponseSchemaWatch.confirmedJSONKeys(
                    in: item,
                    provider: .qwen,
                    endpoint: "Qwen entitlement"
                )
                if let frequencies = item["frequency"] as? [[String: Any]] {
                    var parsedFrequencies: [(code: String, used: Double, resetsAt: Date?)] = []
                    for freq in frequencies {
                        warnings += ResponseSchemaWatch.confirmedJSONKeys(
                            in: freq,
                            provider: .qwen,
                            endpoint: "Qwen frequency"
                        )
                        guard let freqCode = ProviderParsing.string(freq["frequencyEntitlementCode"]), !freqCode.isEmpty,
                              let used = QuotaDiscovery.number(freq["usedPercent"]),
                              (0...100).contains(used) else {
                            continue
                        }
                        let rawReset = ProviderParsing.date(freq["refreshAt"])
                        let resetsAt = rawReset.flatMap { $0 > now.addingTimeInterval(5) ? $0 : nil }
                        parsedFrequencies.append((code: freqCode, used: used, resetsAt: resetsAt))
                    }
                    parsedFrequencies.sort { lhs, rhs in
                        let l = frequencySortKey(lhs.code)
                        let r = frequencySortKey(rhs.code)
                        if l.major != r.major { return l.major > r.major }
                        if l.minor != r.minor { return l.minor > r.minor }
                        if l.isStable != r.isStable { return l.isStable && !r.isStable }
                        return l.code < r.code
                    }
                    if let latest = parsedFrequencies.first.map({ frequencySortKey($0.code) }) {
                        parsedFrequencies.removeAll {
                            let key = frequencySortKey($0.code)
                            return key.major != latest.major || key.minor != latest.minor
                        }
                    }
                    for freq in parsedFrequencies {
                        let kind = QuotaKind.additional(
                            id: "qwen.freq." + freq.code,
                            title: frequencyModelTitle(freq.code)
                        )
                        if !otherWindows.contains(where: { $0.kind == kind }) {
                            otherWindows.append(QuotaWindow(
                                kind: kind,
                                usedPercent: freq.used,
                                resetsAt: freq.resetsAt
                            ))
                        }
                    }
                }
                guard let code = item["entitlementCode"] as? String, !code.isEmpty else { continue }
                if code == "task_assistant" {
                    // Shares the same 7-day Agent & Qwen Code pool already reported by agent/usage.
                    if let total = QuotaDiscovery.number(item["total"]), total > 0,
                       let balance = QuotaDiscovery.number(item["balance"]), (0...total).contains(balance) {
                        weeklyBalance = balance
                        weeklyTotal = total
                    }
                    continue
                }
                if let total = QuotaDiscovery.number(item["total"]), total > 0,
                   let balance = QuotaDiscovery.number(item["balance"]), (0...total).contains(balance) {
                    let usedPercent = (total - balance) / total * 100
                    let resetDate = ProviderParsing.date(item["expireAt"])
                    switch code {
                    case "model_shared_usage":
                        if dailyWindow == nil {
                            dailyWindow = QuotaWindow(
                                kind: .daily,
                                usedPercent: usedPercent,
                                resetsAt: resetDate,
                                remainingCount: balance,
                                limitCount: total
                            )
                        }
                    case "daily_credits":
                        if videoCreditsWindow == nil {
                            videoCreditsWindow = QuotaWindow(
                                kind: .additional(id: "qwen.daily_credits", title: "Video Credits"),
                                usedPercent: usedPercent,
                                resetsAt: resetDate,
                                remainingCount: balance,
                                limitCount: total
                            )
                        }
                    case "image_generation":
                        if imageGenerationWindow == nil {
                            imageGenerationWindow = QuotaWindow(
                                kind: .additional(id: "qwen.image_generation", title: "Image Generation"),
                                usedPercent: usedPercent,
                                resetsAt: resetDate,
                                remainingCount: balance,
                                limitCount: total
                            )
                        }
                    default:
                        let kind = quotaKind(for: code)
                        if !otherWindows.contains(where: { $0.kind == kind }) {
                            otherWindows.append(QuotaWindow(
                                kind: kind,
                                usedPercent: usedPercent,
                                resetsAt: resetDate,
                                remainingCount: balance,
                                limitCount: total
                            ))
                        }
                    }
                } else if item["total"] != nil && !(item["total"] is NSNull) {
                    notices.append(QuotaDiscovery.notice("qwen." + code))
                }
            }
        }

        let weeklyWindow = QuotaWindow(
            kind: .weekly,
            usedPercent: max(0, min(100, 100 - remaining)),
            resetsAt: ProviderParsing.date(data["resetAt"]),
            remainingCount: weeklyBalance,
            limitCount: weeklyTotal
        )

        var windows: [QuotaWindow] = [
            dailyWindow ?? QuotaWindow(
                kind: .daily,
                usedPercent: 0,
                resetsAt: nil,
                isInactive: true,
                inactiveDetail: "Not on plan"
            ),
            weeklyWindow,
            videoCreditsWindow ?? QuotaWindow(
                kind: .additional(id: "qwen.daily_credits", title: "Video Credits"),
                usedPercent: 0,
                resetsAt: nil,
                isInactive: true,
                inactiveDetail: "Not on plan"
            ),
            imageGenerationWindow ?? QuotaWindow(
                kind: .additional(id: "qwen.image_generation", title: "Image Generation"),
                usedPercent: 0,
                resetsAt: nil,
                isInactive: true,
                inactiveDetail: "Not on plan"
            )
        ]
        windows.append(contentsOf: otherWindows)

        var resets: UsageResets?
        if let resetCards {
            warnings += ResponseSchemaWatch.httpHeaders(resetCards, provider: .qwen, endpoint: "Qwen resets")
            if resetCards.statusCode == 200,
               let resetsRoot = try? ProviderParsing.object(from: resetCards.body),
               resetsRoot["success"] as? Bool == true,
               let resetsData = resetsRoot["data"] as? [String: Any] {
                warnings += ResponseSchemaWatch.jsonBodyDeprecation(resetsData, provider: .qwen, endpoint: "Qwen resets")
                warnings += ResponseSchemaWatch.confirmedJSONKeys(in: resetsData, provider: .qwen, endpoint: "Qwen resets")
                if let coupons = resetsData["coupons"] as? [[String: Any]], !coupons.isEmpty {
                    let expirations = coupons.compactMap {
                        ProviderParsing.date($0["gmtExpire"] ?? $0["expireAt"] ?? $0["expiresAt"])
                    }
                    let active = UsageResets(availableCount: coupons.count, expirations: expirations).active(at: now)
                    if active.availableCount > 0 {
                        resets = active
                    }
                }
            }
        }

        if let memberLevel {
            warnings += ResponseSchemaWatch.httpHeaders(memberLevel, provider: .qwen, endpoint: "Qwen member")
            if memberLevel.statusCode == 200,
               let memberRoot = try? ProviderParsing.object(from: memberLevel.body),
               memberRoot["success"] as? Bool == true,
               let memberData = memberRoot["data"] as? [String: Any] {
                warnings += ResponseSchemaWatch.jsonBodyDeprecation(memberData, provider: .qwen, endpoint: "Qwen member")
                warnings += ResponseSchemaWatch.confirmedJSONKeys(in: memberData, provider: .qwen, endpoint: "Qwen member")
                if let memberType = ProviderParsing.string(memberData["memberType"]),
                   let enumWarning = ResponseSchemaWatch.confirmedEnum(
                       memberType,
                       provider: .qwen,
                       endpoint: "Qwen member",
                       field: "memberType"
                   ) {
                    warnings.append(enumWarning)
                }
            }
        } else if let memberType = ProviderParsing.string(data["memberType"]),
                  let enumWarning = ResponseSchemaWatch.confirmedEnum(
                      memberType,
                      provider: .qwen,
                      endpoint: "Qwen member",
                      field: "memberType"
                  ) {
            warnings.append(enumWarning)
        }
        let planName = resolvePlanName(memberLevel: memberLevel, agentUsageData: data)

        return ProviderSnapshot(
            provider: .qwen,
            planName: planName,
            windows: windows,
            resets: resets,
            fetchedAt: now,
            credentialSource: sourceLabel,
            accountLabel: email ?? historyID,
            accountEmail: email,
            usageScope: "Shared account limits • Chat, Agent & Qwen Code",
            usageDetails: notices,
            diagnosticWarnings: ResponseSchemaWatch.deduplicated(warnings)
        )
    }

    static func frequencyModelTitle(_ code: String) -> String {
        let rawTokens = frequencyCodeTokens(code)
        let hasVersionToken = rawTokens.contains { $0.first?.isNumber == true }
        let filteredTokens = hasVersionToken
            ? rawTokens.filter { $0.lowercased() != "max" }
            : rawTokens
        return filteredTokens.map { token in
            if token.first?.isNumber == true {
                return normalizedVersionToken(token)
            }
            return token.prefix(1).uppercased() + token.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    static func frequencySortKey(_ code: String) -> (major: Int, minor: Int, isStable: Bool, code: String) {
        let tokens = frequencyCodeTokens(code)
        var major = 0
        var minor = 0
        for token in tokens where token.first?.isNumber == true {
            let parts = token.split(separator: ".")
            if let first = parts.first, let parsedMajor = Int(first) {
                major = parsedMajor
                minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
                break
            }
        }
        let isStable = !tokens.contains { $0.lowercased() == "preview" }
        return (major: major, minor: minor, isStable: isStable, code: code.lowercased())
    }

    private static func frequencyCodeTokens(_ code: String) -> [String] {
        code
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .flatMap { rawPart -> [String] in
                let part = String(rawPart)
                if part.lowercased().hasPrefix("qwen"),
                   part.count > 4,
                   let next = part.dropFirst(4).first,
                   next.isNumber {
                    return ["Qwen", String(part.dropFirst(4))]
                }
                return [part]
            }
    }

    private static func normalizedVersionToken(_ token: String) -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 2, parts[1].allSatisfy({ $0 == "0" }), !parts[1].isEmpty {
            return String(parts[0])
        }
        return token
    }

    private static func quotaKind(for code: String) -> QuotaKind {
        .additional(id: "qwen." + code, title: QuotaDiscovery.name(code))
    }

    private static func resolvePlanName(memberLevel: HTTPResponse?, agentUsageData: [String: Any]) -> String? {
        var rawTier: String?
        if let memberLevel,
           memberLevel.statusCode == 200,
           let memberRoot = try? ProviderParsing.object(from: memberLevel.body),
           memberRoot["success"] as? Bool == true,
           let memberData = memberRoot["data"] as? [String: Any] {
            rawTier = ProviderParsing.string(memberData["memberType"])
                ?? ProviderParsing.string(memberData["memberName"])
        }
        if rawTier == nil {
            rawTier = ProviderParsing.string(agentUsageData["memberType"])
        }
        guard let normalized = rawTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        switch normalized {
        case "free": return "Free"
        case "lite", "go": return "Lite"
        case "plus": return "Plus"
        case "pro": return "Pro"
        default: return rawTier
        }
    }
}
