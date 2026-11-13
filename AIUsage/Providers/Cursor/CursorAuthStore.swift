import Foundation

struct CursorAuthState: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case sqlite
        case sqliteEncrypted
        case keychain
    }

    var accessToken: String?
    let refreshToken: String?
    let source: Source
}

struct CursorAuthStore: Sendable {
    static let stateDatabasePath =
        "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let accessTokenKey = "cursorAuth/accessToken"
    static let refreshTokenKey = "cursorAuth/refreshToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    static let accessTokenService = "cursor-access-token"
    static let refreshTokenService = "cursor-refresh-token"

    let sqlite: SQLiteValueReading
    let keychain: KeychainAccessing
    let dateProvider: DateProviding

    init(
        sqlite: SQLiteValueReading = SQLiteCLIValueReader(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.dateProvider = dateProvider
    }

    func load() throws -> CursorAuthState? {
        let storedAccess = stateValue(Self.accessTokenKey)
        let storedRefresh = stateValue(Self.refreshTokenKey)
        let encrypted = [storedAccess, storedRefresh].contains {
            $0?.hasPrefix("cursor-safe-storage:") == true
        }
        var password: String?
        func decode(_ value: String?) throws -> String? {
            guard let value, value.hasPrefix("cursor-safe-storage:") else { return value }
            let key: String
            if let password {
                key = password
            } else {
                key = try safeStoragePassword()
                password = key
            }
            return try CursorTokenCodec.decode(value, password: key)
        }
        let sqliteAccess = try decode(storedAccess)
        let sqliteRefresh = try decode(storedRefresh)
        let membership = stateValue(Self.membershipTypeKey)?.lowercased()
        let keychainAccess = keychainValue(Self.accessTokenService)
        let keychainRefresh = keychainValue(Self.refreshTokenService)

        if sqliteAccess != nil || sqliteRefresh != nil {
            let subjectsDiffer =
                tokenSubject(sqliteAccess) != nil &&
                tokenSubject(keychainAccess) != nil &&
                tokenSubject(sqliteAccess) != tokenSubject(keychainAccess)
            if membership == "free",
               subjectsDiffer,
               keychainAccess != nil || keychainRefresh != nil {
                return CursorAuthState(
                    accessToken: keychainAccess,
                    refreshToken: keychainRefresh,
                    source: .keychain
                )
            }
            return CursorAuthState(
                accessToken: sqliteAccess,
                refreshToken: sqliteRefresh,
                source: encrypted ? .sqliteEncrypted : .sqlite
            )
        }

        guard keychainAccess != nil || keychainRefresh != nil else {
            return nil
        }
        return CursorAuthState(
            accessToken: keychainAccess,
            refreshToken: keychainRefresh,
            source: .keychain
        )
    }

    func needsRefresh(_ accessToken: String?) -> Bool {
        guard let accessToken,
              let expiration = ProviderParsing.jwtExpiration(accessToken)
        else {
            return true
        }
        return expiration.timeIntervalSince(dateProvider.now()) <= 300
    }

    func saveAccessToken(
        _ token: String,
        source: CursorAuthState.Source
    ) throws {
        switch source {
        case .sqlite, .sqliteEncrypted:
            let storedToken: String
            if source == .sqliteEncrypted {
                storedToken = try CursorTokenCodec.encode(token, password: safeStoragePassword())
            } else {
                storedToken = token
            }
            let sql =
                "INSERT OR REPLACE INTO ItemTable (key, value) VALUES " +
                "('\(Self.sqlEscaped(Self.accessTokenKey))', " +
                "'\(Self.sqlEscaped(storedToken))');"
            try sqlite.execute(path: Self.stateDatabasePath, sql: sql)
        case .keychain:
            try keychain.writeGenericPassword(
                service: Self.accessTokenService,
                value: token
            )
        }
    }

    private func safeStoragePassword() throws -> String {
        let password: String?
        do {
            password = try keychain.readGenericPassword(service: CursorTokenCodec.keychainService)
        } catch {
            throw ProviderFailure(.storage,
                "Cannot access Cursor Safe Storage in Keychain. Allow access and refresh again.")
        }
        guard let password, !password.isEmpty else {
            throw ProviderFailure(.storage,
                "Cursor Safe Storage key is missing. Open Cursor and sign in again.")
        }
        return password
    }

    private func stateValue(_ key: String) -> String? {
        let sql =
            "SELECT value FROM ItemTable WHERE key = " +
            "'\(Self.sqlEscaped(key))' LIMIT 1"
        guard let value = try? sqlite.queryValue(
            path: Self.stateDatabasePath,
            sql: sql
        ) else {
            return nil
        }
        return Self.nonempty(value)
    }

    private func keychainValue(_ service: String) -> String? {
        guard let value = try? keychain.readGenericPassword(
            service: service
        ) else {
            return nil
        }
        return Self.nonempty(value)
    }

    private func tokenSubject(_ token: String?) -> String? {
        guard let token,
              let data = token.split(
                separator: ".",
                omittingEmptySubsequences: false
              ).dropFirst().first.flatMap({
                  ProviderParsing.base64URLData(String($0))
              }),
              let object = try? JSONSerialization.jsonObject(
                with: data
              ) as? [String: Any]
        else {
            return nil
        }
        return ProviderParsing.string(object["sub"])
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
