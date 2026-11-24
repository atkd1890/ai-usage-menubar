import CryptoKit
import Foundation

struct GeminiWebSession: Sendable {
    let cookieHeader: String
}

struct GeminiAuthStore: Sendable {
    static let cookieAccessKey = "geminiChromeCookiesAllowed.v1"
    static let keychainService = "Chrome Safe Storage"
    static let cookiePaths = [
        "~/Library/Application Support/Google/Chrome/Default/Cookies",
        "~/Library/Application Support/Google/Chrome/Default/Network/Cookies"
    ]
    let sqlite: any SQLiteValueReading
    let keychain: any KeychainAccessing
    let files: any TextFileAccessing
    // nil reads the user's current setting, so toggling access works without relaunch.
    let allowChromeCookies: Bool?

    init(sqlite: any SQLiteValueReading = ReadOnlySessionSQLiteReader(),
         keychain: any KeychainAccessing = SecurityKeychainAccessor(),
         files: any TextFileAccessing = LocalTextFileAccessor(),
         allowChromeCookies: Bool? = nil) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.files = files
        self.allowChromeCookies = allowChromeCookies
    }

    func loadSession(source: GeminiCredentialSource = .chrome) throws -> GeminiWebSession {
        let cookies = try loadCookies(source: source, host: ".google.com", names: ["__Secure-1PSID", "__Secure-1PSIDTS"])
        guard cookies["__Secure-1PSID"] != nil else { throw Self.signInRequired }
        let header = cookies.keys.sorted().map { "\($0)=\(cookies[$0]!)" }.joined(separator: "; ")
        return GeminiWebSession(cookieHeader: header)
    }

    /// Reads only the exact allowlisted cookie names for one exact host from the selected browser's default profile.
    /// Returns an empty dictionary when none of the names are stored.
    func loadCookies(source: GeminiCredentialSource, host: String, names: [String]) throws -> [String: String] {
        guard let browser = source.browser else { throw Self.signInRequired }
        guard allowChromeCookies ?? UserDefaults.standard.bool(forKey: browser.accessKey) else {
            throw ProviderFailure(.authentication,
                "Enable access to the selected browser login in Gemini Settings.")
        }
        guard let path = browser.cookiePaths.first(where: { files.exists($0) }) else {
            throw Self.signInRequired
        }
        let scopedAccess = BrowserDatabaseAccess.start(path: path)
        defer { scopedAccess?.stopAccessingSecurityScopedResource() }
        let allowed = Set(names)
        guard !names.isEmpty, Self.isSafeSQLLiteral(host), names.allSatisfy(Self.isSafeSQLLiteral) else {
            throw Self.storageFailure
        }
        let list = names.map { "'\($0)'" }.joined(separator: ", ")
        let query = "SELECT json_group_array(json_object('name', name, 'host', host_key, 'value', value, 'encrypted', hex(encrypted_value))) FROM cookies WHERE host_key = '\(host)' AND name IN (\(list))"
        let text: String
        let version: Int
        do {
            guard let raw = try sqlite.queryValue(path: path, sql: query),
                  let schema = try sqlite.queryValue(path: path, sql: "SELECT value FROM meta WHERE key = 'version'"),
                  let parsed = Int(schema) else { throw Self.storageFailure }
            text = raw
            version = parsed
        } catch { throw Self.storageFailure }
        guard let data = text.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            throw Self.storageFailure
        }
        var password: String?
        var cookies: [String: String] = [:]
        for row in rows {
            guard let name = row["name"], allowed.contains(name), row["host"] == host else { continue }
            let token: String
            if let plain = row["value"], !plain.isEmpty {
                token = plain
            } else {
                if password == nil {
                    do { password = try keychain.readGenericPassword(service: browser.keychainService) }
                    catch { throw Self.keychainFailure }
                }
                guard let password, !password.isEmpty else { throw Self.keychainFailure }
                token = try Self.decryptCookie(hex: row["encrypted"] ?? "", host: host, version: version, password: password)
            }
            // Cookie values must not introduce headers or extra cookies.
            guard !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0 == ";" }) else {
                throw Self.storageFailure
            }
            cookies[name] = token
        }
        return cookies
    }

    private static func isSafeSQLLiteral(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }

    static func decryptCookie(hex: String, host: String, version: Int, password: String) throws -> String {
        do { return try ChromiumSafeStorageCodec.decryptCookie(hex: hex, host: host, version: version, password: password) }
        catch { throw storageFailure }
    }

    static var signInRequired: ProviderFailure {
        ProviderFailure(.authentication, "Sign in to Gemini in the selected browser’s default profile, then refresh.")
    }
    static var storageFailure: ProviderFailure {
        ProviderFailure(.storage, "Gemini’s selected browser login could not be read or decrypted.")
    }
    static var keychainFailure: ProviderFailure {
        ProviderFailure(.storage, "Allow the selected browser’s Safe Storage access in Keychain to read Gemini usage.")
    }
}
