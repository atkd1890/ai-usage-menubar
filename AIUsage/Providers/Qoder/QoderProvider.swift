import CryptoKit
import Foundation

struct QoderPersistedSession: Codable, Equatable, Sendable {
    var seedFingerprint: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var refreshTokenExpiresAt: Date?
    var email: String?
    var updatedAt: Date
}

struct QoderSessionStore: Sendable {
    static let defaultPath = "~/Library/Application Support/AI Usage/qoder-auth.json"

    let files: any TextFileAccessing
    let path: String

    init(
        files: any TextFileAccessing = LocalTextFileAccessor(),
        path: String = Self.defaultPath
    ) {
        self.files = files
        self.path = path
    }

    func load(for sourceLabel: String) -> QoderPersistedSession? {
        loadAll()[sourceLabel]
    }

    func save(_ session: QoderPersistedSession, for sourceLabel: String) {
        var all = loadAll()
        all[sourceLabel] = session
        writeAll(all)
    }

    func remove(for sourceLabel: String) {
        var all = loadAll()
        guard all.removeValue(forKey: sourceLabel) != nil else { return }
        writeAll(all)
    }

    private func loadAll() -> [String: QoderPersistedSession] {
        guard files.exists(path),
              let text = try? files.readText(path),
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: QoderPersistedSession].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func writeAll(_ sessions: [String: QoderPersistedSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? files.writeText(path, String(decoding: data, as: UTF8.self))
    }
}

struct QoderDesktopSeed: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let refreshTokenExpiresAt: Date?
    let email: String?
    let userID: String?
    let sourceLabel: String
}

enum QoderAuthSeed: Equatable, Sendable {
    case desktop(QoderDesktopSeed)
    case browser(cookieHeader: String, sourceLabel: String)
}

struct QoderAuthLoader: Sendable {
    static let defaultDesktopAuthPath = "~/Library/Application Support/com.qoder.app.stable/auth.v1.dat"
    static let defaultIDEDatabasePath = "~/Library/Application Support/Qoder/User/globalStorage/state.vscdb"
    static let desktopKeychainService = "Qoder App Safe Storage"
    static let ideKeychainService = "Qoder Safe Storage"
    static let ideUserInfoKey = "secret://aicoding.auth.userInfo"

    let files: any TextFileAccessing
    let keychain: any KeychainAccessing
    let sqlite: any SQLiteValueReading
    let sessions: WebSessionStore
    let desktopAuthPath: String
    let ideDatabasePath: String
    let dataReader: @Sendable (String) throws -> Data

    init(
        files: any TextFileAccessing = LocalTextFileAccessor(),
        keychain: any KeychainAccessing = SecurityKeychainAccessor(),
        sqlite: any SQLiteValueReading = SQLiteCLIValueReader(),
        sessions: WebSessionStore = WebSessionStore(),
        desktopAuthPath: String = Self.defaultDesktopAuthPath,
        ideDatabasePath: String = Self.defaultIDEDatabasePath,
        dataReader: @escaping @Sendable (String) throws -> Data = {
            try Data(contentsOf: URL(fileURLWithPath: expandHome($0)))
        }
    ) {
        self.files = files
        self.keychain = keychain
        self.sqlite = sqlite
        self.sessions = sessions
        self.desktopAuthPath = desktopAuthPath
        self.ideDatabasePath = ideDatabasePath
        self.dataReader = dataReader
    }

    func load(method: ProviderLoginMethod) throws -> QoderAuthSeed {
        switch method {
        case .edge, .chrome:
            let source: WebSessionSource = method == .chrome ? .chrome : .edge
            let label = method == .chrome ? "Chrome Default" : "Edge Default"
            do {
                let header = try sessions.cookies(source: source, domain: "qoder.com", names: ["qoder_session_cookie"])
                guard header.contains("qoder_session_cookie=") else {
                    throw ProviderFailure(.authentication, "Sign in to Qoder in \(label) (qoder.com), then refresh.")
                }
                return .browser(cookieHeader: header, sourceLabel: label)
            } catch let failure as ProviderFailure {
                if failure.kind == .storage { throw failure }
                throw ProviderFailure(.authentication, "Sign in to Qoder in \(label) (qoder.com), then refresh.")
            }
        default:
            if let desktopSeed = try? loadDesktopAppSeed() {
                return .desktop(desktopSeed)
            }
            if let ideSeed = try? loadIDEAppSeed() {
                return .desktop(ideSeed)
            }
            throw ProviderFailure(.authentication, "Sign in to Qoder desktop, then refresh.")
        }
    }

    func loadDesktopAppSeed() throws -> QoderDesktopSeed? {
        guard files.exists(desktopAuthPath) else { return nil }
        let encrypted = try dataReader(desktopAuthPath)
        guard let password = try keychain.readGenericPassword(service: Self.desktopKeychainService),
              !password.isEmpty else {
            throw ProviderFailure(.storage, "Qoder App Safe Storage is unavailable.")
        }
        let decrypted = try ChromiumSafeStorageCodec.decrypt(encrypted, password: password)
        let object = try ProviderParsing.object(from: decrypted)
        guard let token = ProviderParsing.string(object["token"]), Self.validToken(token) else {
            return nil
        }
        let user = ProviderParsing.object(object["user"])
        return QoderDesktopSeed(
            accessToken: token,
            refreshToken: ProviderParsing.string(object["refreshToken"]).flatMap { Self.validToken($0) ? $0 : nil },
            expiresAt: ProviderParsing.date(object["expiresAt"]),
            refreshTokenExpiresAt: ProviderParsing.date(object["refreshTokenExpiresAt"]),
            email: AccountEmail.validated(user?["email"]),
            userID: ProviderParsing.string(user?["id"]),
            sourceLabel: "Qoder desktop"
        )
    }

    func loadIDEAppSeed() throws -> QoderDesktopSeed? {
        guard files.exists(ideDatabasePath) else { return nil }
        let sql = "SELECT value FROM ItemTable WHERE key='\(Self.ideUserInfoKey)' LIMIT 1"
        guard let rawValue = try sqlite.queryValue(path: ideDatabasePath, sql: sql),
              let rawData = rawValue.data(using: .utf8),
              let container = try? ProviderParsing.object(from: rawData),
              let byteNumbers = container["data"] as? [NSNumber] else {
            return nil
        }
        let encrypted = Data(byteNumbers.map(\.uint8Value))
        guard let password = try keychain.readGenericPassword(service: Self.ideKeychainService),
              !password.isEmpty else {
            throw ProviderFailure(.storage, "Qoder Safe Storage is unavailable.")
        }
        let decrypted = try ChromiumSafeStorageCodec.decrypt(encrypted, password: password)
        let object = try ProviderParsing.object(from: decrypted)
        guard let token = ProviderParsing.string(object["token"]), Self.validToken(token) else {
            return nil
        }
        return QoderDesktopSeed(
            accessToken: token,
            refreshToken: ProviderParsing.string(object["refreshToken"]).flatMap { Self.validToken($0) ? $0 : nil },
            expiresAt: ProviderParsing.date(object["expireTime"] ?? object["expiresAt"]),
            refreshTokenExpiresAt: ProviderParsing.date(object["refreshTokenExpireTime"] ?? object["refreshTokenExpiresAt"]),
            email: AccountEmail.validated(object["email"]),
            userID: ProviderParsing.string(object["id"] ?? object["user_id"]),
            sourceLabel: "Qoder IDE"
        )
    }

    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(where: { $0.isWhitespace })
    }
}

actor QoderProvider: UsageProvider {
    nonisolated let id = ProviderID.qoder

    static let openAPIBase = "https://openapi.qoder.sh"
    static let webBase = "https://qoder.com"
    static let desktopUsageURL = URL(string: "\(openAPIBase)/sash/api/v2/me/usage")!
    static let desktopPlanURL = URL(string: "\(openAPIBase)/api/v2/user/plan")!
    static let refreshURL = URL(string: "\(openAPIBase)/api/v1/deviceToken/refresh")!
    static let webUsageURL = URL(string: "\(webBase)/sash/api/v2/me/usage")!

    private let http: any HTTPClient
    private let authLoader: @Sendable (ProviderLoginMethod) throws -> QoderAuthSeed
    private let method: @Sendable () -> ProviderLoginMethod
    private let sessionStore: QoderSessionStore?
    private let now: @Sendable () -> Date
    private var memoryCache: (fingerprint: String, session: QoderDesktopSeed)?

    init(
        http: (any HTTPClient)? = nil,
        authLoader: (@Sendable (ProviderLoginMethod) throws -> QoderAuthSeed)? = nil,
        method: (@Sendable () -> ProviderLoginMethod)? = nil,
        sessionStore: QoderSessionStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http ?? GeminiReadOnlyHTTPClient(allowedHosts: ["openapi.qoder.sh", "qoder.com"])
        self.authLoader = authLoader ?? { method in try QoderAuthLoader().load(method: method) }
        self.method = method ?? { ProviderLoginMethod.selected(for: .qoder) }
        self.sessionStore = sessionStore ?? (http == nil ? QoderSessionStore() : nil)
        self.now = now
    }

    func fetch() async throws -> ProviderSnapshot {
        let selectedMethod = method()
        let load = authLoader
        let seed = try await Task.detached(priority: .utility) { try load(selectedMethod) }.value

        switch seed {
        case let .browser(cookieHeader, sourceLabel):
            let response = try await http.send(HTTPRequest(
                method: .get,
                url: Self.webUsageURL,
                headers: [
                    "Accept": "application/json",
                    "Cookie": cookieHeader
                ],
                body: nil
            ))
            let historyID = "qoder-session:" + Self.sha256Hex(sourceLabel + "\0" + cookieHeader)
            return try Self.map(
                usage: response,
                plan: nil,
                email: nil,
                credentialSource: sourceLabel,
                historyID: historyID,
                now: now()
            )

        case let .desktop(desktopSeed):
            return try await fetchDesktop(seed: desktopSeed)
        }
    }

    private func fetchDesktop(seed: QoderDesktopSeed) async throws -> ProviderSnapshot {
        let seedFingerprint = Self.sha256Hex(seed.sourceLabel + "\0" + (seed.refreshToken ?? seed.accessToken))
        let historyID = "qoder-session:" + Self.sha256Hex(seed.userID ?? (seed.sourceLabel + "\0" + (seed.refreshToken ?? seed.accessToken)))

        var current = resolveInitialSession(seed: seed, seedFingerprint: seedFingerprint)
        let currentDate = now()
        if let expiresAt = current.expiresAt,
           expiresAt <= currentDate.addingTimeInterval(120),
           canRefresh(current, at: currentDate) {
            current = try await refreshDesktopSession(
                current,
                seedFingerprint: seedFingerprint,
                fallbackRefresh: seed.refreshToken
            )
        }

        for attempt in 0...1 {
            let usageResponse = try await http.send(Self.desktopGET(Self.desktopUsageURL, accessToken: current.accessToken))
            if [401, 403].contains(usageResponse.statusCode) {
                if attempt == 0, canRefresh(current, at: now()) {
                    current = try await refreshDesktopSession(
                        current,
                        seedFingerprint: seedFingerprint,
                        fallbackRefresh: seed.refreshToken
                    )
                    continue
                }
                invalidateSession(for: current.sourceLabel)
                throw ProviderFailure(.authentication, "Sign in to Qoder desktop, then refresh.")
            }

            let planResponse = try? await http.send(Self.desktopGET(Self.desktopPlanURL, accessToken: current.accessToken))
            return try Self.map(
                usage: usageResponse,
                plan: planResponse,
                email: current.email,
                credentialSource: current.sourceLabel,
                historyID: historyID,
                now: now()
            )
        }

        invalidateSession(for: current.sourceLabel)
        throw ProviderFailure(.authentication, "Sign in to Qoder desktop, then refresh.")
    }

    private func resolveInitialSession(seed: QoderDesktopSeed, seedFingerprint: String) -> QoderDesktopSeed {
        if let cached = memoryCache, cached.fingerprint == seedFingerprint {
            return cached.session
        }
        if let persisted = sessionStore?.load(for: seed.sourceLabel) {
            if persisted.seedFingerprint == seedFingerprint, QoderAuthLoader.validToken(persisted.accessToken) {
                let merged = QoderDesktopSeed(
                    accessToken: persisted.accessToken,
                    refreshToken: persisted.refreshToken.flatMap { QoderAuthLoader.validToken($0) ? $0 : nil } ?? seed.refreshToken,
                    expiresAt: persisted.expiresAt ?? seed.expiresAt,
                    refreshTokenExpiresAt: persisted.refreshTokenExpiresAt ?? seed.refreshTokenExpiresAt,
                    email: persisted.email ?? seed.email,
                    userID: seed.userID,
                    sourceLabel: seed.sourceLabel
                )
                memoryCache = (seedFingerprint, merged)
                return merged
            }
            sessionStore?.remove(for: seed.sourceLabel)
        }
        return seed
    }

    private func canRefresh(_ session: QoderDesktopSeed, at date: Date) -> Bool {
        guard let refreshToken = session.refreshToken, QoderAuthLoader.validToken(refreshToken) else {
            return false
        }
        if let refreshExpiresAt = session.refreshTokenExpiresAt, refreshExpiresAt <= date {
            return false
        }
        return true
    }

    private func refreshDesktopSession(
        _ session: QoderDesktopSeed,
        seedFingerprint: String,
        fallbackRefresh: String?
    ) async throws -> QoderDesktopSeed {
        guard let refreshToken = session.refreshToken, QoderAuthLoader.validToken(refreshToken) else {
            invalidateSession(for: session.sourceLabel)
            throw ProviderFailure(.authentication, "Sign in to Qoder desktop, then refresh.")
        }

        var response = try await sendRefresh(refreshToken: refreshToken)
        if [400, 401, 403].contains(response.statusCode),
           let fallbackRefresh,
           fallbackRefresh != refreshToken,
           QoderAuthLoader.validToken(fallbackRefresh) {
            response = try await sendRefresh(refreshToken: fallbackRefresh)
        }

        if [400, 401, 403].contains(response.statusCode) {
            invalidateSession(for: session.sourceLabel)
            throw ProviderFailure(.authentication, "Sign in to Qoder desktop, then refresh.")
        }
        guard response.statusCode == 200 else {
            throw ProviderFailure(.transient, "Qoder token refresh returned HTTP \(response.statusCode).")
        }

        let body = try ProviderParsing.object(from: response.body)
        guard let newAccess = ProviderParsing.string(body["device_token"] ?? body["token"]),
              QoderAuthLoader.validToken(newAccess) else {
            throw ProviderFailure(.invalidResponse, "Qoder token refresh returned no valid access token.")
        }
        let nextRefresh = ProviderParsing.string(body["refresh_token"]) ?? refreshToken
        guard QoderAuthLoader.validToken(nextRefresh) else {
            throw ProviderFailure(.invalidResponse, "Qoder token refresh returned an invalid refresh token.")
        }

        let currentDate = now()
        let nextExpiresAt = Self.expiryDate(
            timestamp: body["expire_time"] ?? body["expires_at"],
            expiresIn: body["expires_in"],
            now: currentDate
        ) ?? session.expiresAt
        let nextRefreshExpiresAt = Self.expiryDate(
            timestamp: body["refresh_token_expire_time"] ?? body["refresh_token_expires_at"],
            expiresIn: body["refresh_token_expires_in"],
            now: currentDate
        ) ?? session.refreshTokenExpiresAt

        let updated = QoderDesktopSeed(
            accessToken: newAccess,
            refreshToken: nextRefresh,
            expiresAt: nextExpiresAt,
            refreshTokenExpiresAt: nextRefreshExpiresAt,
            email: session.email,
            userID: session.userID,
            sourceLabel: session.sourceLabel
        )
        memoryCache = (seedFingerprint, updated)
        sessionStore?.save(
            QoderPersistedSession(
                seedFingerprint: seedFingerprint,
                accessToken: updated.accessToken,
                refreshToken: updated.refreshToken,
                expiresAt: updated.expiresAt,
                refreshTokenExpiresAt: updated.refreshTokenExpiresAt,
                email: updated.email,
                updatedAt: currentDate
            ),
            for: session.sourceLabel
        )
        return updated
    }

    private func sendRefresh(refreshToken: String) async throws -> HTTPResponse {
        let payload = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        return try await http.send(HTTPRequest(
            method: .post,
            url: Self.refreshURL,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/json"
            ],
            body: payload
        ))
    }

    private func invalidateSession(for sourceLabel: String) {
        memoryCache = nil
        sessionStore?.remove(for: sourceLabel)
    }

    private static func desktopGET(_ url: URL, accessToken: String) -> HTTPRequest {
        HTTPRequest(
            method: .get,
            url: url,
            headers: [
                "Accept": "application/json",
                "Authorization": "Bearer \(accessToken)",
                "Cosy-ClientType": "10",
                "User-Agent": "Qoder"
            ],
            body: nil
        )
    }

    private static func expiryDate(timestamp: Any?, expiresIn: Any?, now: Date) -> Date? {
        if let parsed = ProviderParsing.date(timestamp) {
            return parsed
        }
        if let seconds = QuotaDiscovery.number(expiresIn), seconds > 0 {
            return now.addingTimeInterval(seconds)
        }
        return nil
    }

    static func map(
        usage: HTTPResponse,
        plan: HTTPResponse? = nil,
        email: String? = nil,
        credentialSource: String = "Qoder desktop",
        historyID: String,
        now: Date = Date()
    ) throws -> ProviderSnapshot {
        if [401, 403].contains(usage.statusCode) {
            throw ProviderFailure(.authentication, "Qoder session expired. Sign in to \(credentialSource) again.")
        }
        if usage.statusCode == 429 {
            throw ProviderFailure(.rateLimited, "Qoder usage is rate limited.", retryAt: ProviderParsing.retryDate(from: usage, now: now))
        }
        guard usage.statusCode == 200 else {
            throw ProviderFailure(.invalidResponse, "Qoder usage request returned HTTP \(usage.statusCode).")
        }

        let root = try ProviderParsing.object(from: usage.body)
        let displayMode = ProviderParsing.string(root["displayMode"])
        let planFromEndpoint = extractPlanTier(from: plan)

        var warnings = ResponseSchemaWatch.httpHeaders(usage, provider: .qoder, endpoint: "Qoder")
        warnings += ResponseSchemaWatch.jsonBodyDeprecation(root, provider: .qoder, endpoint: "Qoder")
        warnings += ResponseSchemaWatch.confirmedJSONKeys(in: root, provider: .qoder, endpoint: "Qoder")
        if let displayMode,
           let enumWarning = ResponseSchemaWatch.confirmedEnum(
               displayMode,
               provider: .qoder,
               endpoint: "Qoder",
               field: "displayMode"
           ) {
            warnings.append(enumWarning)
        }
        if let plan {
            warnings += ResponseSchemaWatch.httpHeaders(plan, provider: .qoder, endpoint: "Qoder plan")
            if plan.statusCode == 200, let planObj = try? ProviderParsing.object(from: plan.body) {
                warnings += ResponseSchemaWatch.jsonBodyDeprecation(planObj, provider: .qoder, endpoint: "Qoder plan")
                warnings += ResponseSchemaWatch.confirmedJSONKeys(in: planObj, provider: .qoder, endpoint: "Qoder plan")
            }
        }

        if displayMode == "enterprise" {
            return ProviderSnapshot(
                provider: .qoder,
                planName: planFromEndpoint ?? "Enterprise",
                windows: [],
                fetchedAt: now,
                credentialSource: credentialSource,
                accountLabel: email ?? historyID,
                accountEmail: email,
                usageDetails: [
                    ProviderUsageDetail(
                        id: "qoder.enterprise",
                        title: "Usage",
                        value: "Managed by organization"
                    )
                ],
                diagnosticWarnings: ResponseSchemaWatch.deduplicated(warnings)
            )
        }

        guard displayMode == "qoder" || root["qoderUsage"] != nil,
              let qoderUsage = ProviderParsing.object(root["qoderUsage"]) else {
            throw ProviderFailure(.invalidResponse, "Qoder returned an unsupported usage payload.")
        }

        warnings += ResponseSchemaWatch.jsonBodyDeprecation(qoderUsage, provider: .qoder, endpoint: "Qoder usage")
        warnings += ResponseSchemaWatch.confirmedJSONKeys(in: qoderUsage, provider: .qoder, endpoint: "Qoder usage")
        if let usageType = ProviderParsing.string(qoderUsage["usageType"]),
           let enumWarning = ResponseSchemaWatch.confirmedEnum(
               usageType,
               provider: .qoder,
               endpoint: "Qoder usage",
               field: "usageType"
           ) {
            warnings.append(enumWarning)
        }
        if let userType = ProviderParsing.string(qoderUsage["userType"]),
           let enumWarning = ResponseSchemaWatch.confirmedEnum(
               userType,
               provider: .qoder,
               endpoint: "Qoder usage",
               field: "userType"
           ) {
            warnings.append(enumWarning)
        }

        let resetsAt = ProviderParsing.date(qoderUsage["refreshAt"] ?? qoderUsage["expiresAt"])
        var windows: [QuotaWindow] = []
        var details: [ProviderUsageDetail] = []

        if let userQuota = ProviderParsing.object(qoderUsage["userQuota"]) {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(in: userQuota, provider: .qoder, endpoint: "Qoder quota")
            if let window = mapQuotaWindow(userQuota, kind: .credits, resetsAt: resetsAt) {
                windows.append(window)
            }
        }
        var hasAddOnCredits = false
        if let addOnQuota = ProviderParsing.object(qoderUsage["addOnQuota"]) {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(in: addOnQuota, provider: .qoder, endpoint: "Qoder quota")
            if let detail = mapAddOnCredits(addOnQuota) {
                details.append(detail)
                hasAddOnCredits = true
            }
        }
        if let dedicatedPackages = qoderUsage["dedicatedResourcePackages"] as? [[String: Any]] {
            details.append(contentsOf: mapDedicatedPackages(dedicatedPackages, warnings: &warnings))
        }
        if let orgPackage = ProviderParsing.object(qoderUsage["orgResourcePackage"]),
           let detail = mapOrgResourcePackage(orgPackage) {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(in: orgPackage, provider: .qoder, endpoint: "Qoder quota")
            details.append(detail)
        }
        if !windows.isEmpty && !hasAddOnCredits {
            details.append(ProviderUsageDetail(
                id: "qoder.addon.credits",
                title: "Add-on Credits",
                value: "N/A"
            ))
        }

        guard !windows.isEmpty || !details.isEmpty else {
            throw ProviderFailure(.invalidResponse, "Qoder returned no active credit quota.")
        }

        let planName = planFromEndpoint ?? resolvePlanName(from: ProviderParsing.string(qoderUsage["userType"]))
        let responseUserID = ProviderParsing.string(qoderUsage["userId"])
        let resolvedHistoryID = responseUserID.map { "qoder-session:" + sha256Hex($0) } ?? historyID

        return ProviderSnapshot(
            provider: .qoder,
            planName: planName,
            windows: windows,
            fetchedAt: now,
            credentialSource: credentialSource,
            accountLabel: email ?? resolvedHistoryID,
            accountEmail: email,
            usageDetails: details,
            diagnosticWarnings: ResponseSchemaWatch.deduplicated(warnings)
        )
    }

    private static func mapQuotaWindow(
        _ quota: [String: Any],
        kind: QuotaKind,
        resetsAt: Date?
    ) -> QuotaWindow? {
        guard let total = QuotaDiscovery.number(quota["total"]), total > 0 else {
            return nil
        }
        let used = QuotaDiscovery.number(quota["used"])
        let remaining = QuotaDiscovery.number(quota["remaining"]) ?? used.map { max(total - $0, 0) }
        guard let remaining else { return nil }
        let effectiveUsed = used ?? max(total - remaining, 0)
        let rawPercent: Double
        if let reported = QuotaDiscovery.number(quota["percentage"]) {
            rawPercent = (reported > 0 && reported <= 1 && (effectiveUsed / total) > 0.015) ? reported * 100 : reported
        } else {
            rawPercent = effectiveUsed / total * 100
        }
        return QuotaWindow(
            kind: kind,
            usedPercent: min(max(rawPercent, 0), 100),
            resetsAt: resetsAt,
            remainingCount: remaining,
            limitCount: total
        )
    }

    private static func mapDedicatedPackages(
        _ packages: [[String: Any]],
        warnings: inout [ProviderDiagnosticWarning]
    ) -> [ProviderUsageDetail] {
        var result: [ProviderUsageDetail] = []
        for package in packages {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(in: package, provider: .qoder, endpoint: "Qoder dedicated package")
            guard let total = QuotaDiscovery.number(package["total"]), total > 0 else { continue }
            let used = QuotaDiscovery.number(package["used"])
            guard let remaining = QuotaDiscovery.number(package["remaining"]) ?? used.map({ max(total - $0, 0) }) else {
                continue
            }
            let effectiveUsed = used ?? max(total - remaining, 0)
            let rawTitle = ProviderParsing.string(package["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (rawTitle?.isEmpty == false) ? rawTitle! : "Dedicated Credits"
            let rawKey = ProviderParsing.string(package["id"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let keyHash = sha256Hex((rawKey?.isEmpty == false) ? rawKey! : title)
            result.append(ProviderUsageDetail(
                id: "qoder.dedicated.\(keyHash).credits",
                title: title,
                value: "\(formatCount(remaining)) / \(formatCount(total)) left",
                boundedProgress: BoundedCreditProgress(
                    label: title,
                    used: effectiveUsed,
                    limit: total,
                    resetsAt: nil,
                    resetNote: nil
                )
            ))
            if let expiry = ProviderParsing.date(package["expiresAt"] ?? package["expires_at"]) {
                result.append(ProviderUsageDetail(
                    id: "qoder.dedicated.\(keyHash).expiry",
                    title: "\(title) expires",
                    value: expiry.formatted(date: .abbreviated, time: .shortened),
                    targetDate: expiry
                ))
            }
        }
        return result
    }

    private static func mapAddOnCredits(_ quota: [String: Any]) -> ProviderUsageDetail? {
        guard let total = QuotaDiscovery.number(quota["total"]), total > 0 else {
            return nil
        }
        let used = QuotaDiscovery.number(quota["used"])
        guard let remaining = QuotaDiscovery.number(quota["remaining"]) ?? used.map({ max(total - $0, 0) }) else {
            return nil
        }
        let effectiveUsed = used ?? max(total - remaining, 0)
        return ProviderUsageDetail(
            id: "qoder.addon.credits",
            title: "Add-on Credits",
            value: "\(formatCount(remaining)) / \(formatCount(total)) left",
            boundedProgress: BoundedCreditProgress(
                label: "Add-on",
                used: effectiveUsed,
                limit: total,
                resetsAt: nil,
                resetNote: "No reset"
            )
        )
    }

    private static func mapOrgResourcePackage(_ package: [String: Any]) -> ProviderUsageDetail? {
        let used = QuotaDiscovery.number(package["used"])
        let total = QuotaDiscovery.number(package["total"]) ?? QuotaDiscovery.number(package["cap"])
        let remaining = QuotaDiscovery.number(package["remaining"])
        let value: String
        let boundedProgress: BoundedCreditProgress?
        if let total, total > 0 {
            let shownUsed = used ?? remaining.map { max(total - $0, 0) } ?? 0
            value = "\(formatCount(shownUsed)) / \(formatCount(total))"
            boundedProgress = BoundedCreditProgress(
                label: "Org pool",
                used: shownUsed,
                limit: total,
                resetsAt: nil,
                resetNote: "No reset"
            )
        } else if let used {
            value = "\(formatCount(used)) used"
            boundedProgress = nil
        } else {
            return nil
        }
        return ProviderUsageDetail(
            id: "qoder.org.credits",
            title: "Org Credits",
            value: value,
            boundedProgress: boundedProgress
        )
    }

    private static func extractPlanTier(from plan: HTTPResponse?) -> String? {
        guard let plan,
              plan.statusCode == 200,
              let obj = try? ProviderParsing.object(from: plan.body) else {
            return nil
        }
        return ProviderParsing.string(
            obj["plan_tier_name"] ?? obj["planTierName"] ?? obj["plan_name"] ?? obj["planName"]
        )
    }

    static func resolvePlanName(from userType: String?) -> String? {
        guard let raw = userType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "personal_professional_trial": return "Pro Trial"
        case "personal_pro", "pro": return "Pro"
        case "personal_ultra", "ultra": return "Ultra"
        case "personal_free", "free": return "Free"
        default:
            let cleaned = ProviderParsing.titleCaseIdentifier(raw.replacingOccurrences(of: "-", with: "_"))
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    private static func formatCount(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded.rounded() == rounded {
            return Int(rounded).formatted(.number)
        }
        return rounded.formatted(.number.precision(.fractionLength(0...2)))
    }

    private static func sha256Hex(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).map { String(format: "%02x", $0) }.joined()
    }
}
