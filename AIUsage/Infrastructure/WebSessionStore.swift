import Foundation
import SQLite3

enum WebSessionSource: String, Sendable {
    case edge, chrome, claudeDesktop, codexDesktop, manusDesktop
    var directory: String {
        switch self {
        case .edge: "Microsoft Edge/Default"
        case .chrome: "Google/Chrome/Default"
        case .claudeDesktop: "Claude"
        case .codexDesktop: "Codex"
        case .manusDesktop: "Manus"
        }
    }
    var keychainService: String {
        switch self {
        case .edge: "Microsoft Edge Safe Storage"
        case .chrome: "Chrome Safe Storage"
        case .claudeDesktop: "Claude Safe Storage"
        case .codexDesktop: "Codex Safe Storage"
        case .manusDesktop: "Manus Safe Storage"
        }
    }
}

/// Narrow, read-only cookie import. No copy, cache, token logging or writes.
struct WebSessionStore: Sendable {
    let sqlite: any SQLiteValueReading
    let keychain: any KeychainAccessing
    let files: any TextFileAccessing
    init(sqlite: any SQLiteValueReading = ReadOnlySessionSQLiteReader(),
         keychain: any KeychainAccessing = SecurityKeychainAccessor(),
         files: any TextFileAccessing = LocalTextFileAccessor()) {
        self.sqlite = sqlite; self.keychain = keychain; self.files = files
    }
    func cookies(source: WebSessionSource, domain: String, names: [String]) throws -> String {
        let allowed: [String: Set<String>] = [
            "claude.ai": ["sessionKey", "sessionKeyLC", "sessionKeyV3", "sessionKeyV3LC"],
            "chatgpt.com": ["__Secure-next-auth.session-token", "__Secure-next-auth.session-token.0", "__Secure-next-auth.session-token.1"],
            "cursor.com": ["WorkosCursorSessionToken"],
            "manus.im": ["session_id"],
            "muse.ai": ["hatch_sess", "hatch_gw"],
            "qwen.ai": ["refresh_token"],
            "kimi.ai": ["kimi-auth"],
            "services.adobe.com": ["ims_sid"],
            "qoder.com": ["qoder_session_cookie"],
            "design.minimax.io": ["_token"]]
        guard !names.isEmpty, Set(names).isSubset(of: allowed[domain] ?? []),
              source != .claudeDesktop || domain == "claude.ai",
              source != .codexDesktop || domain == "chatgpt.com",
              source != .manusDesktop || domain == "manus.im" else {
            throw ProviderFailure(.storage, "Unsupported session cookie request.")
        }
        let base = "~/Library/Application Support/\(source.directory)/"
        guard let path = [base + "Cookies", base + "Network/Cookies"].first(where: files.exists) else {
            throw ProviderFailure(.authentication, "No session found in the selected app or browser.")
        }
        let selectedAccess = ["manus.im", "muse.ai", "qwen.ai", "kimi.ai", "services.adobe.com", "qoder.com", "design.minimax.io"].contains(domain) && (source == .edge || source == .chrome) ? BrowserDatabaseAccess.start(path: path) : nil
        defer { selectedAccess?.stopAccessingSecurityScopedResource() }
        let hosts: Set<String>
        switch domain {
        case "manus.im":
            hosts = ["manus.im", ".manus.im", "api.manus.im", ".api.manus.im"]
        case "kimi.ai":
            hosts = ["kimi.ai", ".kimi.ai", "www.kimi.ai", ".www.kimi.ai"]
        case "services.adobe.com":
            hosts = ["services.adobe.com", ".services.adobe.com", "adobe.com", ".adobe.com"]
        case "qoder.com":
            hosts = ["qoder.com", ".qoder.com"]
        case "design.minimax.io":
            hosts = ["design.minimax.io", ".design.minimax.io", "minimax.io", ".minimax.io", "agent.minimax.io", ".agent.minimax.io"]
        default:
            hosts = [domain, "." + domain]
        }
        let hostList = hosts.sorted().map { "'\($0)'" }.joined(separator: ",")
        let nameList = names.map { "'\($0)'" }.joined(separator: ",")
        let sql = "SELECT json_group_array(json_object('name',name,'host',host_key,'value',value,'encrypted',hex(encrypted_value))) FROM cookies WHERE host_key IN (\(hostList)) AND name IN (\(nameList))"
        guard let raw = try sqlite.queryValue(path: path, sql: sql), let data = raw.data(using: .utf8),
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: String]], !rows.isEmpty,
              let versionRaw = try sqlite.queryValue(path: path, sql: "SELECT value FROM meta WHERE key='version'"), let version = Int(versionRaw) else {
            throw ProviderFailure(.authentication, "Sign in to the service in the selected app or browser.")
        }
        var password: String?
        var result: [String: String] = [:]
        for row in rows {
            guard let name = row["name"], names.contains(name), let host = row["host"], hosts.contains(host) else { continue }
            let value: String
            if let plain = row["value"], !plain.isEmpty { value = plain }
            else {
                if password == nil { password = try keychain.readGenericPassword(service: source.keychainService) }
                guard let password else { throw ProviderFailure(.storage, "The selected Safe Storage is unavailable.") }
                value = try GeminiAuthStore.decryptCookie(hex: row["encrypted"] ?? "", host: host, version: version, password: password)
            }
            guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0 == ";" }) else { throw ProviderFailure(.storage, "Invalid session cookie format.") }
            if let old = result[name], old != value { throw ProviderFailure(.authentication, "Conflicting account cookies. Sign in again.") }
            result[name] = value
        }
        guard !result.isEmpty else { throw ProviderFailure(.authentication, "No session cookies found.") }
        return result.keys.sorted().map { "\($0)=\(result[$0]!)" }.joined(separator: "; ")
    }
}

struct ReadOnlySessionSQLiteReader: SQLiteValueReading {
    func queryValue(path: String, sql: String) throws -> String? {
        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(expandHome(path), &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard openStatus == SQLITE_OK else {
            let permissionDenied = openStatus == SQLITE_AUTH || db.map { sqlite3_system_errno($0) == 1 || sqlite3_system_errno($0) == 13 } ?? false
            if let db { sqlite3_close(db) }
            throw ProviderFailure(.storage, permissionDenied
                ? "macOS denied access to the selected app or browser data. Allow AI Usage access in Privacy & Security, then refresh."
                : "The session database could not be opened read-only.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProviderFailure(.storage, "The session database format is unsupported.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
    func execute(path: String, sql: String) throws {
        throw ProviderFailure(.storage, "Session databases are read-only.")
    }
}
