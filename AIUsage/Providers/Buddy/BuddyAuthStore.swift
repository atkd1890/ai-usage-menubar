import Foundation

struct BuddyCredential: Sendable {
    let headers: [String: String]
    let host: String
    let source: String
    let fingerprint: String
    let accountID: String?
}

struct BuddyAuthStore: Sendable {
    static let tokenKey = #"secret://{"extensionId":"tencent-cloud.coding-copilot","key":"planning-genie.new.accessToken"}"#
    let sqlite: any SQLiteValueReading
    let keychain: any KeychainAccessing
    let sessions: WebSessionStore
    init(sqlite: any SQLiteValueReading = ReadOnlySessionSQLiteReader(), keychain: any KeychainAccessing = SecurityKeychainAccessor()) {
        self.sqlite = sqlite; self.keychain = keychain
        sessions = WebSessionStore(sqlite: sqlite, keychain: keychain)
    }
    func load(_ method: ProviderLoginMethod) throws -> BuddyCredential {
        if method == .desktop {
            let path = "~/Library/Application Support/CodeBuddy/User/globalStorage/state.vscdb"
            do {
                guard let raw = try sqlite.queryValue(path: path, sql: "SELECT value FROM ItemTable WHERE key='\(Self.tokenKey)' LIMIT 1") else {
                    throw ProviderFailure(.authentication, "Sign in to CodeBuddy desktop.")
                }
                guard let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      let numbers = object["data"] as? [NSNumber], !numbers.isEmpty,
                      numbers.count < 1_000_000 else { throw ProviderFailure(.storage, "CodeBuddy desktop credential format changed.") }
                guard let password = try keychain.readGenericPassword(service: "CodeBuddy Safe Storage") else {
                    throw ProviderFailure(.storage, "CodeBuddy desktop Safe Storage is unavailable.")
                }
                let plaintext = try ChromiumSafeStorageCodec.decrypt(Data(numbers.map(\.uint8Value)), password: password)
                guard let session = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
                      let auth = session["auth"] as? [String: Any],
                      auth["domain"] as? String == "www.codebuddy.ai",
                      let account = session["account"] as? [String: Any], let uid = account["uid"] as? String,
                      account["type"] as? String == "personal",
                      let rawToken = auth["accessToken"] as? String else {
                    throw ProviderFailure(.authentication, "Select an international personal account in CodeBuddy desktop.")
                }
                let token = try Self.token(Data(rawToken.utf8))
                return BuddyCredential(headers: ["Authorization": "Bearer " + token], host: "www.codebuddy.ai", source: "CodeBuddy desktop", fingerprint: ZAIAuthStore.hash(uid), accountID: uid)
            } catch let failure as ProviderFailure {
                if failure.kind == .storage { throw ProviderFailure(.storage, "CodeBuddy desktop login could not be read or decrypted. Check its Safe Storage access.") }
                throw failure
            }
            catch { throw ProviderFailure(.storage, "CodeBuddy desktop login could not be read or decrypted. Check its Safe Storage access.") }
        }
        let source: WebSessionSource
        switch method {
        case .edge: source = .edge
        case .chrome: source = .chrome
        default: throw ProviderFailure(.storage, "Unsupported Buddy login method.")
        }
        let cookie: String
        do { cookie = try sessions.cookies(source: source, domain: "www.codebuddy.ai", names: ["session", "session_2"]) }
        catch let failure as ProviderFailure {
            throw ProviderFailure(failure.kind, "Buddy login in CodeBuddy web (" + (method == .edge ? "Edge" : "Chrome") + ") could not be read. Check that selected source's login and storage access.")
        }
        return BuddyCredential(headers: ["Cookie": cookie], host: "www.codebuddy.ai", source: "CodeBuddy · " + (method == .edge ? "Edge Default" : "Chrome Default"), fingerprint: ZAIAuthStore.hash(cookie), accountID: nil)
    }
    static func token(_ plaintext: Data) throws -> String {
        var value = String(data: plaintext, encoding: .utf8)
        if let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] {
            value = (object["accessToken"] as? String) ?? (object["token"] as? String)
        } else if let decoded = try? JSONSerialization.jsonObject(with: plaintext, options: [.fragmentsAllowed]) as? String { value = decoded }
        guard let value, !value.isEmpty, value.count < 64_000, !value.contains("\r"), !value.contains("\n") else {
            throw ProviderFailure(.storage, "CodeBuddy token format changed.")
        }
        return value.hasPrefix("Bearer ") ? String(value.dropFirst(7)) : value
    }
}
