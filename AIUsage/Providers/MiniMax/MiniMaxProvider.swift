import CryptoKit
import Foundation

struct MiniMaxPersistedSession: Codable, Equatable, Sendable {
    var seedFingerprint: String
    var accessToken: String
    var refreshToken: String?
    var expiresAtMs: Double?
    var updatedAt: Date
}

struct MiniMaxSessionStore: Sendable {
    static let defaultPath = "~/Library/Application Support/AI Usage/minimax-auth.json"

    let files: any TextFileAccessing
    let path: String

    init(
        files: any TextFileAccessing = LocalTextFileAccessor(),
        path: String = Self.defaultPath
    ) {
        self.files = files
        self.path = path
    }

    func load(for sourceLabel: String) -> MiniMaxPersistedSession? {
        loadAll()[sourceLabel]
    }

    func save(_ session: MiniMaxPersistedSession, for sourceLabel: String) {
        var all = loadAll()
        all[sourceLabel] = session
        writeAll(all)
    }

    func remove(for sourceLabel: String) {
        var all = loadAll()
        guard all.removeValue(forKey: sourceLabel) != nil else { return }
        writeAll(all)
    }

    private func loadAll() -> [String: MiniMaxPersistedSession] {
        guard files.exists(path),
              let text = try? files.readText(path),
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: MiniMaxPersistedSession].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func writeAll(_ sessions: [String: MiniMaxPersistedSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? files.writeText(path, String(decoding: data, as: UTF8.self))
    }
}

enum MiniMaxDesignCodec {
    static func decryptV2Enc(_ stored: String, keyData: Data) throws -> String {
        guard !stored.hasPrefix("encrypted:") else {
            throw ProviderFailure(.storage, "Legacy encrypted MiniMax session is unsupported.")
        }
        guard stored.hasPrefix("v2enc:") else {
            return stored
        }
        let remainder = stored.dropFirst("v2enc:".count)
        let parts = remainder.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let iv = Data(base64Encoded: String(parts[0])),
              let tag = Data(base64Encoded: String(parts[1])),
              let ciphertext = Data(base64Encoded: String(parts[2])),
              keyData.count == 32 else {
            throw ProviderFailure(.storage, "MiniMax Design session encoding is invalid.")
        }
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData))
        guard let decoded = String(data: plaintext, encoding: .utf8), !decoded.isEmpty else {
            throw ProviderFailure(.storage, "MiniMax Design session could not be decoded.")
        }
        return decoded
    }
}

enum MiniMaxSigning {
    private static let signatureSecret = "I*7Cf%WZ#S&%1RlZJ&C2"

    static func signedRequest(
        method: HTTPRequest.Method,
        baseURL: String,
        path: String,
        bizID: String,
        body: String?,
        tokenHeader: String?,
        bearerToken: String?,
        now: Date = Date()
    ) -> HTTPRequest {
        let unixMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let unixSec = Int64(now.timeIntervalSince1970)
        var components = URLComponents(string: baseURL + path)!
        components.queryItems = [
            URLQueryItem(name: "device_platform", value: "web"),
            URLQueryItem(name: "biz_id", value: bizID),
            URLQueryItem(name: "app_id", value: "3001"),
            URLQueryItem(name: "version_code", value: "22201"),
            URLQueryItem(name: "unix", value: String(unixMs)),
            URLQueryItem(name: "timezone_offset", value: String(TimeZone.current.secondsFromGMT())),
            URLQueryItem(name: "sys_language", value: "en"),
            URLQueryItem(name: "lang", value: "en"),
            URLQueryItem(name: "device_id", value: "0"),
            URLQueryItem(name: "os_name", value: "darwin"),
            URLQueryItem(name: "browser_name", value: "mcode"),
            URLQueryItem(name: "user_id", value: "0"),
            URLQueryItem(name: "client", value: "desktop")
        ]
        let url = components.url!
        let pathAndQuery = url.path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let encodedPath = encodeURIComponent(pathAndQuery)
        let bodyString = body ?? ""
        let yyBody = bodyString.isEmpty ? "{}" : bodyString
        let yy = md5Hex("\(encodedPath)_\(yyBody)\(md5Hex(String(unixMs)))ooui")
        let xSignature = md5Hex("\(unixSec)\(signatureSecret)\(bodyString)")

        var headers: [String: String] = [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "yy": yy,
            "x-timestamp": String(unixSec),
            "x-signature": xSignature
        ]
        if let tokenHeader, !tokenHeader.isEmpty {
            headers["token"] = tokenHeader
        }
        if let bearerToken, !bearerToken.isEmpty {
            headers["Authorization"] = "Bearer \(bearerToken)"
        }
        return HTTPRequest(
            method: method,
            url: url,
            headers: headers,
            body: method == .post ? Data(bodyString.utf8) : nil
        )
    }

    static func encodeURIComponent(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)
        return value.utf8.map { byte in
            allowed.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }

    static func md5Hex(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct MiniMaxCodeOAuthSeed: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let clientID: String
    let scopes: [String]
    let audience: String
    let expiresAtMs: Double?
}

struct MiniMaxDesignSeed: Equatable, Sendable {
    let jwtToken: String
    let groupID: String?
    let userID: String?
}

struct MiniMaxDesktopSeed: Equatable, Sendable {
    let codeOAuth: MiniMaxCodeOAuthSeed?
    let design: MiniMaxDesignSeed?
    let sourceLabel: String
}

enum MiniMaxAuthSeed: Equatable, Sendable {
    case desktop(MiniMaxDesktopSeed)
    case browser(jwtToken: String, sourceLabel: String)
}

struct MiniMaxAuthLoader: Sendable {
    static let defaultCodeOAuthPaths = [
        "~/.minimax/auth/prod/en/mcode-public/auth.json",
        "~/.minimax/auth/prod/cn/mcode-public/auth.json"
    ]
    static let defaultHubDir = "~/Library/Application Support/@hilo/MiniMax Hub Global"

    let files: any TextFileAccessing
    let sessions: WebSessionStore
    let codeOAuthPaths: [String]
    let hubDirectory: String
    let keyReader: @Sendable (String) throws -> Data

    init(
        files: any TextFileAccessing = LocalTextFileAccessor(),
        sessions: WebSessionStore = WebSessionStore(),
        codeOAuthPaths: [String] = Self.defaultCodeOAuthPaths,
        hubDirectory: String = Self.defaultHubDir,
        keyReader: @escaping @Sendable (String) throws -> Data = {
            try Data(contentsOf: URL(fileURLWithPath: expandHome($0)))
        }
    ) {
        self.files = files
        self.sessions = sessions
        self.codeOAuthPaths = codeOAuthPaths
        self.hubDirectory = hubDirectory
        self.keyReader = keyReader
    }

    func load(method: ProviderLoginMethod) throws -> MiniMaxAuthSeed {
        switch method {
        case .edge, .chrome:
            let source: WebSessionSource = method == .chrome ? .chrome : .edge
            let label = method == .chrome ? "Chrome Default" : "Edge Default"
            do {
                let header = try sessions.cookies(source: source, domain: "design.minimax.io", names: ["_token"])
                guard let token = Self.cookieValue(named: "_token", in: header), Self.validToken(token) else {
                    throw ProviderFailure(.authentication, "Sign in to MiniMax in \(label) (design.minimax.io), then refresh.")
                }
                return .browser(jwtToken: token, sourceLabel: label)
            } catch let failure as ProviderFailure {
                if failure.kind == .storage { throw failure }
                throw ProviderFailure(.authentication, "Sign in to MiniMax in \(label) (design.minimax.io), then refresh.")
            }

        default:
            let codeOAuth = loadCodeOAuthSeed()
            let design = loadDesignSeed()
            guard codeOAuth != nil || design != nil else {
                throw ProviderFailure(.authentication, "Sign in to MiniMax desktop, then refresh.")
            }
            return .desktop(MiniMaxDesktopSeed(
                codeOAuth: codeOAuth,
                design: design,
                sourceLabel: "MiniMax desktop"
            ))
        }
    }

    func loadCodeOAuthSeed() -> MiniMaxCodeOAuthSeed? {
        for path in codeOAuthPaths where files.exists(path) {
            guard let text = try? files.readText(path),
                  let data = text.data(using: .utf8),
                  let root = try? ProviderParsing.object(from: data),
                  let records = ProviderParsing.object(root["records"]) else {
                continue
            }
            for rawRecord in records.values {
                guard let record = ProviderParsing.object(rawRecord),
                      let access = ProviderParsing.string(record["accessToken"]),
                      Self.validToken(access) else {
                    continue
                }
                let scopes = (record["scopes"] as? [String])?.filter { !$0.isEmpty } ?? ["agent.default"]
                return MiniMaxCodeOAuthSeed(
                    accessToken: access,
                    refreshToken: ProviderParsing.string(record["refreshToken"]).flatMap { Self.validToken($0) ? $0 : nil },
                    clientID: ProviderParsing.string(record["clientId"]) ?? "mcode-public",
                    scopes: scopes.isEmpty ? ["agent.default"] : scopes,
                    audience: ProviderParsing.string(record["audience"]) ?? "agent-backend",
                    expiresAtMs: ProviderParsing.double(record["expiresAtMs"])
                )
            }
        }
        return nil
    }

    func loadDesignSeed() -> MiniMaxDesignSeed? {
        let configPath = hubDirectory + "/hub-config-global.json"
        let keyPath = hubDirectory + "/.token-key"
        guard files.exists(configPath),
              let text = try? files.readText(configPath),
              let data = text.data(using: .utf8),
              let root = try? ProviderParsing.object(from: data),
              let tokens = ProviderParsing.object(root["tokens"]),
              let storedToken = ProviderParsing.string(tokens["accessToken"]) else {
            return nil
        }

        let jwtToken: String
        if storedToken.hasPrefix("v2enc:") {
            guard let keyData = try? keyReader(keyPath),
                  let decrypted = try? MiniMaxDesignCodec.decryptV2Enc(storedToken, keyData: keyData) else {
                return nil
            }
            jwtToken = decrypted
        } else {
            guard !storedToken.hasPrefix("encrypted:") else { return nil }
            jwtToken = storedToken
        }
        guard Self.validToken(jwtToken) else { return nil }

        let user = ProviderParsing.object(root["user"])
        let userID = ProviderParsing.string(user?["userID"])
        let groupIDs = ProviderParsing.object(root["selectedGroupIds"])
        let groupID = userID.flatMap { ProviderParsing.string(groupIDs?[$0]) }
            ?? groupIDs?.values.compactMap { ProviderParsing.string($0) }.first

        return MiniMaxDesignSeed(jwtToken: jwtToken, groupID: groupID, userID: userID)
    }

    private static func cookieValue(named name: String, in header: String) -> String? {
        let prefix = "\(name)="
        for item in header.components(separatedBy: ";") {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
        }
        return nil
    }

    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(where: { $0.isWhitespace || $0 == ";" })
    }
}

actor MiniMaxProvider: UsageProvider {
    nonisolated let id = ProviderID.minimax

    static let platformOrigin = "https://platform.minimax.io"
    static let agentOrigin = "https://agent.minimax.io"
    static let designOrigin = "https://design.minimax.io"
    static let hailuoOrigin = "https://hailuoai.video"
    static let accountOrigin = "https://account.minimax.io"

    static let oauthRefreshURL = URL(string: "\(accountOrigin)/oauth2/token")!
    static let remainsPercentURL = URL(string: "\(platformOrigin)/backend/account/token_plan/remains_percent")!
    static let tokenPlanCreditURL = URL(string: "\(platformOrigin)/backend/account/token_plan_credit")!
    static let designWalletURL = URL(string: "\(designOrigin)/api/v1/credit/wallet")!
    static let designProfileURL = URL(string: "\(designOrigin)/api/v1/account/profile")!

    private let http: any HTTPClient
    private let authLoader: @Sendable (ProviderLoginMethod) throws -> MiniMaxAuthSeed
    private let method: @Sendable () -> ProviderLoginMethod
    private let sessionStore: MiniMaxSessionStore?
    private let now: @Sendable () -> Date

    init(
        http: (any HTTPClient)? = nil,
        authLoader: (@Sendable (ProviderLoginMethod) throws -> MiniMaxAuthSeed)? = nil,
        method: (@Sendable () -> ProviderLoginMethod)? = nil,
        sessionStore: MiniMaxSessionStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http ?? GeminiReadOnlyHTTPClient(allowedHosts: [
            "platform.minimax.io",
            "agent.minimax.io",
            "design.minimax.io",
            "hailuoai.video",
            "account.minimax.io"
        ])
        self.authLoader = authLoader ?? { method in try MiniMaxAuthLoader().load(method: method) }
        self.method = method ?? { ProviderLoginMethod.selected(for: .minimax) }
        self.sessionStore = sessionStore ?? (http == nil ? MiniMaxSessionStore() : nil)
        self.now = now
    }

    func fetch() async throws -> ProviderSnapshot {
        let selectedMethod = method()
        let load = authLoader
        let seed = try await Task.detached(priority: .utility) { try load(selectedMethod) }.value
        let currentDate = now()

        switch seed {
        case let .browser(jwtToken, sourceLabel):
            return try await fetchWithSignals(
                oauthAccess: nil,
                jwtToken: jwtToken,
                groupID: nil,
                userIDHint: Self.jwtUserID(jwtToken),
                credentialSource: sourceLabel,
                refreshFailedOnly: false,
                now: currentDate
            )

        case let .desktop(desktopSeed):
            var activeOAuth = desktopSeed.codeOAuth
            var oauthRefreshFailed = false
            if let oauthSeed = desktopSeed.codeOAuth {
                let seedFingerprint = Self.sha256Hex("MiniMax desktop\0" + (oauthSeed.refreshToken ?? oauthSeed.accessToken))
                activeOAuth = resolveOAuthSession(seed: oauthSeed, seedFingerprint: seedFingerprint)
                if let resolved = activeOAuth,
                   let expiresAtMs = resolved.expiresAtMs,
                   expiresAtMs <= currentDate.timeIntervalSince1970 * 1000 + 120_000,
                   let refreshToken = resolved.refreshToken,
                   MiniMaxAuthLoader.validToken(refreshToken) {
                    if let refreshed = await refreshCodeOAuth(
                        resolved,
                        seedFingerprint: seedFingerprint,
                        fallbackRefresh: oauthSeed.refreshToken,
                        now: currentDate
                    ) {
                        activeOAuth = refreshed
                    } else {
                        oauthRefreshFailed = true
                        activeOAuth = nil
                    }
                }
            }

            return try await fetchWithSignals(
                oauthAccess: activeOAuth?.accessToken,
                jwtToken: desktopSeed.design?.jwtToken,
                groupID: desktopSeed.design?.groupID,
                userIDHint: desktopSeed.design?.userID ?? desktopSeed.design.flatMap { Self.jwtUserID($0.jwtToken) },
                credentialSource: desktopSeed.sourceLabel,
                refreshFailedOnly: oauthRefreshFailed && desktopSeed.design == nil,
                now: now()
            )
        }
    }

    private func resolveOAuthSession(
        seed: MiniMaxCodeOAuthSeed,
        seedFingerprint: String
    ) -> MiniMaxCodeOAuthSeed {
        guard let persisted = sessionStore?.load(for: "MiniMax desktop") else {
            return seed
        }
        guard persisted.seedFingerprint == seedFingerprint,
              MiniMaxAuthLoader.validToken(persisted.accessToken) else {
            sessionStore?.remove(for: "MiniMax desktop")
            return seed
        }
        return MiniMaxCodeOAuthSeed(
            accessToken: persisted.accessToken,
            refreshToken: persisted.refreshToken.flatMap { MiniMaxAuthLoader.validToken($0) ? $0 : nil } ?? seed.refreshToken,
            clientID: seed.clientID,
            scopes: seed.scopes,
            audience: seed.audience,
            expiresAtMs: persisted.expiresAtMs ?? seed.expiresAtMs
        )
    }

    private func refreshCodeOAuth(
        _ session: MiniMaxCodeOAuthSeed,
        seedFingerprint: String,
        fallbackRefresh: String?,
        now: Date
    ) async -> MiniMaxCodeOAuthSeed? {
        guard let refreshToken = session.refreshToken else { return nil }
        var response = try? await sendOAuthRefresh(session, refreshToken: refreshToken)
        if let first = response,
           [400, 401, 403].contains(first.statusCode),
           let fallbackRefresh,
           fallbackRefresh != refreshToken,
           MiniMaxAuthLoader.validToken(fallbackRefresh) {
            response = try? await sendOAuthRefresh(session, refreshToken: fallbackRefresh)
        }
        guard let response else { return nil }
        if [400, 401, 403].contains(response.statusCode) {
            sessionStore?.remove(for: "MiniMax desktop")
            return nil
        }
        guard response.statusCode == 200,
              let body = try? ProviderParsing.object(from: response.body),
              let access = ProviderParsing.string(body["access_token"]),
              MiniMaxAuthLoader.validToken(access) else {
            return nil
        }
        let nextRefresh = ProviderParsing.string(body["refresh_token"]) ?? refreshToken
        guard MiniMaxAuthLoader.validToken(nextRefresh) else { return nil }

        let expiresIn = QuotaDiscovery.number(body["expires_in"])
        let expiresAtMs: Double? = if let expiresIn, expiresIn > 0 {
            now.timeIntervalSince1970 * 1000 + expiresIn * 1000
        } else {
            ProviderParsing.jwtExpiration(access).map { $0.timeIntervalSince1970 * 1000 } ?? session.expiresAtMs
        }

        let updated = MiniMaxCodeOAuthSeed(
            accessToken: access,
            refreshToken: nextRefresh,
            clientID: session.clientID,
            scopes: session.scopes,
            audience: session.audience,
            expiresAtMs: expiresAtMs
        )
        sessionStore?.save(
            MiniMaxPersistedSession(
                seedFingerprint: seedFingerprint,
                accessToken: updated.accessToken,
                refreshToken: updated.refreshToken,
                expiresAtMs: updated.expiresAtMs,
                updatedAt: now
            ),
            for: "MiniMax desktop"
        )
        return updated
    }

    private func sendOAuthRefresh(_ session: MiniMaxCodeOAuthSeed, refreshToken: String) async throws -> HTTPResponse {
        let body = ProviderParsing.formBody([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", session.clientID),
            ("scope", session.scopes.joined(separator: " ")),
            ("audience", session.audience)
        ])
        return try await http.send(HTTPRequest(
            method: .post,
            url: Self.oauthRefreshURL,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded"
            ],
            body: body
        ))
    }

    private func fetchWithSignals(
        oauthAccess: String?,
        jwtToken: String?,
        groupID: String?,
        userIDHint: String?,
        credentialSource: String,
        refreshFailedOnly: Bool,
        now: Date
    ) async throws -> ProviderSnapshot {
        if refreshFailedOnly {
            throw ProviderFailure(.authentication, "Sign in to MiniMax desktop, then refresh.")
        }

        var membership: HTTPResponse?
        var remains: HTTPResponse?
        var tokenPlanCredit: HTTPResponse?
        var wallet: HTTPResponse?
        var profile: HTTPResponse?
        var hailuoCredit: HTTPResponse?
        var hailuoEquity: HTTPResponse?

        var resolvedGroupID = groupID

        if let oauthAccess {
            let memReq = MiniMaxSigning.signedRequest(
                method: .post,
                baseURL: Self.agentOrigin,
                path: "/matrix/api/v1/commerce/get_membership_info",
                bizID: "3",
                body: "{}",
                tokenHeader: nil,
                bearerToken: oauthAccess,
                now: now
            )
            let memResp = try? await http.send(memReq)
            if Self.isAuthenticatedSuccess(memResp) {
                membership = memResp
                if resolvedGroupID == nil,
                   let data = memResp?.body,
                   let obj = try? ProviderParsing.object(from: data) {
                    let inner = ProviderParsing.object(obj["data"]) ?? obj
                    resolvedGroupID = ProviderParsing.string(inner["op_group_id"])
                }
            }

            let remResp = try? await http.send(Self.platformGET(
                Self.remainsPercentURL,
                bearerToken: oauthAccess,
                tokenHeader: nil,
                groupID: resolvedGroupID
            ))
            if Self.isAuthenticatedSuccess(remResp) {
                remains = remResp
            }

            let tpcResp = try? await http.send(Self.platformGET(
                Self.tokenPlanCreditURL,
                bearerToken: oauthAccess,
                tokenHeader: nil,
                groupID: resolvedGroupID
            ))
            if Self.isAuthenticatedSuccess(tpcResp) {
                tokenPlanCredit = tpcResp
            }
        }

        if let jwtToken {
            let walResp = try? await http.send(Self.designGET(Self.designWalletURL, jwt: jwtToken, groupID: resolvedGroupID))
            if Self.isAuthenticatedSuccess(walResp) {
                wallet = walResp
            }

            let profResp = try? await http.send(Self.designGET(Self.designProfileURL, jwt: jwtToken, groupID: resolvedGroupID))
            if Self.isAuthenticatedSuccess(profResp) {
                profile = profResp
            }

            let hCreditReq = MiniMaxSigning.signedRequest(
                method: .get,
                baseURL: Self.hailuoOrigin,
                path: "/v1/api/billing/credit",
                bizID: "1",
                body: nil,
                tokenHeader: jwtToken,
                bearerToken: nil,
                now: now
            )
            let hcResp = try? await http.send(hCreditReq)
            if Self.isAuthenticatedSuccess(hcResp) {
                hailuoCredit = hcResp
            }

            let hEquityReq = MiniMaxSigning.signedRequest(
                method: .get,
                baseURL: Self.hailuoOrigin,
                path: "/v1/api/user/equity",
                bizID: "1",
                body: nil,
                tokenHeader: jwtToken,
                bearerToken: nil,
                now: now
            )
            let heResp = try? await http.send(hEquityReq)
            if Self.isAuthenticatedSuccess(heResp) {
                hailuoEquity = heResp
            }

            if remains == nil {
                let remResp = try? await http.send(Self.platformGET(
                    Self.remainsPercentURL,
                    bearerToken: nil,
                    tokenHeader: jwtToken,
                    groupID: resolvedGroupID
                ))
                if Self.isAuthenticatedSuccess(remResp) {
                    remains = remResp
                }
            }
            if tokenPlanCredit == nil {
                let tpcResp = try? await http.send(Self.platformGET(
                    Self.tokenPlanCreditURL,
                    bearerToken: nil,
                    tokenHeader: jwtToken,
                    groupID: resolvedGroupID
                ))
                if Self.isAuthenticatedSuccess(tpcResp) {
                    tokenPlanCredit = tpcResp
                }
            }
        }

        let anySucceeded = [membership, remains, tokenPlanCredit, wallet, profile, hailuoCredit, hailuoEquity].contains { $0 != nil }
        guard anySucceeded else {
            if credentialSource.contains("Default") {
                throw ProviderFailure(.authentication, "Sign in to MiniMax in \(credentialSource) (design.minimax.io), then refresh.")
            }
            throw ProviderFailure(.authentication, "Sign in to MiniMax desktop, then refresh.")
        }

        let historySeed = userIDHint ?? jwtToken ?? oauthAccess ?? credentialSource
        let historyID = "minimax-session:" + Self.sha256Hex(credentialSource + "\0" + historySeed)

        return try Self.map(
            remains: remains,
            tokenPlanCredit: tokenPlanCredit,
            membership: membership,
            wallet: wallet,
            profile: profile,
            hailuoCredit: hailuoCredit,
            hailuoEquity: hailuoEquity,
            credentialSource: credentialSource,
            historyID: historyID,
            now: now
        )
    }

    static func isAuthenticatedSuccess(_ response: HTTPResponse?) -> Bool {
        guard let response, response.statusCode == 200,
              let obj = try? ProviderParsing.object(from: response.body) else {
            return false
        }
        if let baseResp = ProviderParsing.object(obj["base_resp"]),
           let code = QuotaDiscovery.number(baseResp["status_code"]),
           code != 0 {
            return false
        }
        if let statusInfo = ProviderParsing.object(obj["statusInfo"]),
           let code = QuotaDiscovery.number(statusInfo["code"]),
           code != 0 {
            return false
        }
        return true
    }

    private static func platformGET(
        _ url: URL,
        bearerToken: String?,
        tokenHeader: String?,
        groupID: String?
    ) -> HTTPRequest {
        var headers = ["Accept": "application/json"]
        if let bearerToken { headers["Authorization"] = "Bearer \(bearerToken)" }
        if let tokenHeader { headers["token"] = tokenHeader }
        if let groupID, !groupID.isEmpty { headers["X-Group-Id"] = groupID }
        return HTTPRequest(method: .get, url: url, headers: headers, body: nil)
    }

    private static func designGET(
        _ url: URL,
        jwt: String,
        groupID: String?
    ) -> HTTPRequest {
        var headers = [
            "Accept": "application/json",
            "token": jwt,
            "Authorization": "Bearer \(jwt)"
        ]
        if let groupID, !groupID.isEmpty {
            headers["X-Group-Id"] = groupID
        }
        return HTTPRequest(method: .get, url: url, headers: headers, body: nil)
    }

    static func map(
        remains: HTTPResponse? = nil,
        tokenPlanCredit: HTTPResponse? = nil,
        membership: HTTPResponse? = nil,
        wallet: HTTPResponse? = nil,
        profile: HTTPResponse? = nil,
        hailuoCredit: HTTPResponse? = nil,
        hailuoEquity: HTTPResponse? = nil,
        credentialSource: String = "MiniMax desktop",
        historyID: String = "minimax-session:0000",
        now: Date = Date()
    ) throws -> ProviderSnapshot {
        var windows: [QuotaWindow] = []
        var details: [ProviderUsageDetail] = []

        if let remains, remains.statusCode == 200,
           let remainsObj = try? ProviderParsing.object(from: remains.body) {
            let models = ProviderParsing.array(remainsObj["model_remains"])
            if !models.isEmpty {
                let primary = models.first { ProviderParsing.string($0["model_name"]) == "general" }
                    ?? models.first {
                        guard let name = ProviderParsing.string($0["model_name"]) else { return true }
                        return name.range(of: "video", options: .caseInsensitive) == nil
                    }
                    ?? models.first
                if let primary {
                    let intervalTotal = parsePercent(primary["current_interval_total_percent"])
                    let intervalUsed = parsePercent(primary["current_interval_used_percent"])
                    if intervalTotal != nil || intervalUsed != nil {
                        let total = (intervalTotal ?? 0) > 0 ? intervalTotal! : 100
                        let used = max(intervalUsed ?? 0, 0)
                        let pct = min(max((used / total) * 100, 0), 100)
                        windows.append(QuotaWindow(
                            kind: .session,
                            usedPercent: pct,
                            resetsAt: ProviderParsing.date(primary["end_time"])
                        ))
                    }

                    let weeklyTotal = parsePercent(primary["current_weekly_total_percent"])
                    let weeklyUsed = parsePercent(primary["current_weekly_used_percent"])
                    if weeklyTotal != nil || weeklyUsed != nil {
                        let total = (weeklyTotal ?? 0) > 0 ? weeklyTotal! : 100
                        let used = max(weeklyUsed ?? 0, 0)
                        let pct = min(max((used / total) * 100, 0), 100)
                        windows.append(QuotaWindow(
                            kind: .weekly,
                            usedPercent: pct,
                            resetsAt: ProviderParsing.date(primary["weekly_end_time"])
                        ))
                    }
                }

                if let video = models.first(where: {
                    guard let name = ProviderParsing.string($0["model_name"]),
                          name.range(of: "video", options: .caseInsensitive) != nil,
                          let total = QuotaDiscovery.number($0["current_interval_total_count"]),
                          total > 0 else {
                        return false
                    }
                    return true
                }),
                   let total = QuotaDiscovery.number(video["current_interval_total_count"]), total > 0 {
                    let used = max(QuotaDiscovery.number(video["current_interval_used_count"]) ?? 0, 0)
                    let remaining = max(total - used, 0)
                    windows.append(QuotaWindow(
                        kind: .additional(id: "minimax.video", title: "Video"),
                        usedPercent: min(max((used / total) * 100, 0), 100),
                        resetsAt: ProviderParsing.date(video["end_time"]),
                        remainingCount: remaining,
                        limitCount: total
                    ))
                }
            }
        }
        let hasActiveTokenPlan = !windows.isEmpty

        let membershipRoot = membership.flatMap { resp -> [String: Any]? in
            guard resp.statusCode == 200, let obj = try? ProviderParsing.object(from: resp.body) else { return nil }
            return ProviderParsing.object(obj["data"]) ?? ProviderParsing.object(obj["membership_info"]) ?? obj
        }

        var agentCreditsAmount: Double?
        if let tokenPlanCredit, tokenPlanCredit.statusCode == 200,
           let creditObj = try? ProviderParsing.object(from: tokenPlanCredit.body) {
            let breakdown = ProviderParsing.object(creditObj["balance_breakdown"])
            agentCreditsAmount = QuotaDiscovery.number(creditObj["remaining_credits"])
                ?? QuotaDiscovery.number(breakdown?["total_balance"])
        }
        if (agentCreditsAmount ?? 0) <= 0, let membershipRoot {
            let opSummary = ProviderParsing.object(membershipRoot["op_credit_summary"])
            agentCreditsAmount = QuotaDiscovery.number(opSummary?["total_remaining_amount"])
                ?? QuotaDiscovery.number(membershipRoot["opcredit_balance"])
                ?? QuotaDiscovery.number(membershipRoot["total_remains_credit"])
        }

        if !hasActiveTokenPlan {
            windows = [
                QuotaWindow(
                    kind: .session,
                    usedPercent: 0,
                    resetsAt: nil,
                    isInactive: true,
                    inactiveDetail: "No Token Plan"
                ),
                QuotaWindow(
                    kind: .weekly,
                    usedPercent: 0,
                    resetsAt: nil,
                    isInactive: true,
                    inactiveDetail: "No Token Plan"
                )
            ]
        }

        let walletObj = wallet.flatMap { resp -> [String: Any]? in
            guard resp.statusCode == 200 else { return nil }
            return try? ProviderParsing.object(from: resp.body)
        }
        let walletEntries = ProviderParsing.array(walletObj?["wallets"])
        let designWallet = walletEntries.first { QuotaDiscovery.number($0["source"]) == 1 }
        let hailuoWallet = walletEntries.first { QuotaDiscovery.number($0["source"]) == 0 }

        var creditParts: [String] = []
        if !hasActiveTokenPlan, let agentCreditsAmount, agentCreditsAmount > 0 {
            creditParts.append("Agent \(formatCredits(agentCreditsAmount))")
        }
        if let designWallet, let designCredits = QuotaDiscovery.number(designWallet["total_credit"]) {
            creditParts.append("Design \(formatCredits(designCredits))")
        } else if walletObj != nil, let totalCredit = QuotaDiscovery.number(walletObj?["total_credit"]) {
            creditParts.append("Design \(formatCredits(totalCredit))")
        }

        let hailuoCreditData = hailuoCredit.flatMap { resp -> [String: Any]? in
            guard resp.statusCode == 200,
                  let obj = try? ProviderParsing.object(from: resp.body) else { return nil }
            return ProviderParsing.object(obj["data"]) ?? obj
        }
        if let hailuoAmount = QuotaDiscovery.number(hailuoCreditData?["total_credit"])
            ?? QuotaDiscovery.number(hailuoWallet?["total_credit"]) {
            creditParts.append("Hailuo \(formatCredits(hailuoAmount))")
        }

        details.append(ProviderUsageDetail(
            id: "minimax.credits",
            title: "Additional Credits",
            value: creditParts.isEmpty ? "N/A" : creditParts.joined(separator: " · ")
        ))

        if hasActiveTokenPlan, let agentCreditsAmount, agentCreditsAmount > 0 {
            details.append(ProviderUsageDetail(
                id: "minimax.agent.credits",
                title: "Token Plan Credits",
                value: "\(formatCredits(agentCreditsAmount)) credits"
            ))
        }

        let hailuoEquityData = hailuoEquity.flatMap { resp -> [String: Any]? in
            guard resp.statusCode == 200,
                  let obj = try? ProviderParsing.object(from: resp.body) else { return nil }
            return ProviderParsing.object(obj["data"]) ?? obj
        }

        let planCandidates: [String?] = [
            ProviderParsing.string(membershipRoot?["token_plan_tier"]),
            ProviderParsing.string(membershipRoot?["plan_name"]),
            ProviderParsing.string(designWallet?["plan_name"]),
            ProviderParsing.string(hailuoEquityData?["memberName"])
        ]
        let planName = planCandidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }

        let profileObj = profile.flatMap { resp -> [String: Any]? in
            guard resp.statusCode == 200 else { return nil }
            return try? ProviderParsing.object(from: resp.body)
        }
        let email = AccountEmail.validated(profileObj?["account"])
            ?? AccountEmail.validated(membershipRoot?["email"])
            ?? AccountEmail.validated(membershipRoot?["user_email"])

        return ProviderSnapshot(
            provider: .minimax,
            planName: planName,
            windows: windows,
            fetchedAt: now,
            credentialSource: credentialSource,
            accountLabel: email ?? historyID,
            accountEmail: email,
            usageDetails: details
        )
    }

    static func parsePercent(_ value: Any?) -> Double? {
        if let number = QuotaDiscovery.number(value) {
            return number
        }
        guard let raw = ProviderParsing.string(value) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = Double(trimmed), parsed.isFinite else { return nil }
        return parsed
    }

    private static func formatCredits(_ value: Double) -> String {
        let clamped = max(value, 0)
        let rounded = (clamped * 100).rounded() / 100
        if rounded.rounded() == rounded {
            return Int(rounded).formatted(.number)
        }
        return rounded.formatted(.number.precision(.fractionLength(0...2)))
    }

    private static func jwtUserID(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let data = ProviderParsing.base64URLData(String(parts[1])),
              let obj = try? ProviderParsing.object(from: data) else {
            return nil
        }
        if let user = ProviderParsing.object(obj["user"]),
           let id = ProviderParsing.string(user["id"]) {
            return id
        }
        return ProviderParsing.string(obj["sub"])
    }

    private static func sha256Hex(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).map { String(format: "%02x", $0) }.joined()
    }
}
