import CryptoKit
import Foundation

/// Email is identity metadata, never inferred from another credential source or an organization name.
enum AccountEmail {
    static func validated(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 254,
              value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
    static func jwt(_ token: String) -> String? {
        let pieces = token.split(separator: ".")
        guard pieces.count == 3, let data = ProviderParsing.base64URLData(String(pieces[1])),
              let object = try? ProviderParsing.object(from: data) else { return nil }
        return validated(object["email"]) ?? ProviderParsing.object(object["https://api.openai.com/profile"]).flatMap { validated($0["email"]) }
    }
    static func claude(_ object: [String: Any]) -> String? {
        validated(object["email_address"]) ?? validated(object["email"])
            ?? ProviderParsing.object(object["account"]).flatMap { validated($0["email_address"]) ?? validated($0["email"]) }
    }
    static func cursor(_ object: [String: Any]) -> String? {
        validated(object["email"]) ?? ProviderParsing.object(object["user"]).flatMap { validated($0["email"]) }
    }
}

/// Only the current credential fingerprint and its email are cached in memory.
actor AccountIdentityCache {
    private let provider: ProviderID
    private let storageKey: String
    private let defaults: UserDefaults
    init(provider: ProviderID, source: String, suiteName: String? = nil) {
        self.provider = provider
        self.storageKey = "accountIdentity.v1.\(provider.rawValue).\(source)"
        self.defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
    func read(credential: String, operation: @Sendable () async throws -> String?) async -> String? {
        let selectionKey = ProviderLoginMethod.selectionKey(for: provider)
        let selection = defaults.string(forKey: selectionKey) ?? "initial"
        let fingerprint = SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
        if let saved = defaults.dictionary(forKey: storageKey), saved["selection"] as? String == selection {
            // A changed credential does not trigger another API read or inherit the previous account's email.
            return saved["fingerprint"] as? String == fingerprint ? AccountEmail.validated(saved["email"]) : nil
        }
        // Persist the attempt before awaiting, so failures/restarts do not poll identity endpoints.
        var saved = ["selection": selection, "fingerprint": fingerprint]
        defaults.set(saved, forKey: storageKey)
        let email = AccountEmail.validated(try? await operation())
        guard !Task.isCancelled, (defaults.string(forKey: selectionKey) ?? "initial") == selection,
              defaults.dictionary(forKey: storageKey)?["fingerprint"] as? String == fingerprint else { return nil }
        if let email { saved["email"] = email }
        defaults.set(saved, forKey: storageKey)
        return email
    }
    /// A successful refresh proves continuity with the old credential. This
    /// never transfers identity to an independently changed login.
    func rebindAfterRefresh(from old: String, to new: String) {
        let selection = defaults.string(forKey: ProviderLoginMethod.selectionKey(for: provider)) ?? "initial"
        let before = SHA256.hash(data: Data(old.utf8)).map { String(format: "%02x", $0) }.joined()
        guard var saved = defaults.dictionary(forKey: storageKey), saved["selection"] as? String == selection,
              saved["fingerprint"] as? String == before else { return }
        saved["fingerprint"] = SHA256.hash(data: Data(new.utf8)).map { String(format: "%02x", $0) }.joined()
        defaults.set(saved, forKey: storageKey)
    }

}

struct AccountIdentityClient: Sendable {
    let http: any HTTPClient
    init(http: any HTTPClient = GeminiReadOnlyHTTPClient(allowedHosts: [
        "api.anthropic.com", "claude.ai", "cursor.com", "api.github.com", "accounts.google.com"], timeout: 5)) {
        self.http = http
    }
    private func read(_ url: String, headers: [String: String], post: Bool = false) async throws -> Data? {
        var headers = headers
        headers["Accept"] = "application/json"
        let response = try await http.send(HTTPRequest(method: post ? .post : .get, url: URL(string: url)!, headers: headers, body: post ? Data(" ".utf8) : nil))
        return response.statusCode == 200 ? response.body : nil
    }
    func claudeOAuth(_ token: String) async throws -> String? {
        guard let body = try await read("https://api.anthropic.com/api/oauth/profile", headers: [
            "Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20"]),
              let object = try? ProviderParsing.object(from: body) else { return nil }
        return AccountEmail.claude(object)
    }
    func claudeWeb(_ cookie: String) async throws -> String? {
        guard let body = try await read("https://claude.ai/api/account", headers: ["Cookie": cookie]),
              let object = try? ProviderParsing.object(from: body) else { return nil }
        return AccountEmail.claude(object)
    }
    func cursor(_ cookie: String) async throws -> String? {
        guard let body = try await read("https://cursor.com/api/auth/me", headers: ["Cookie": cookie]),
              let object = try? ProviderParsing.object(from: body) else { return nil }
        return AccountEmail.cursor(object)
    }
    func github(_ token: String) async throws -> String? {
        let headers = ["Authorization": "token " + token, "User-Agent": "AI-Usage"]
        if let body = try? await read("https://api.github.com/user/emails", headers: headers),
           let rows = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]],
           let primary = rows.first(where: { $0["primary"] as? Bool == true }),
           let email = AccountEmail.validated(primary["email"]) { return email }
        guard let body = try await read("https://api.github.com/user", headers: headers),
              let object = try? ProviderParsing.object(from: body) else { return nil }
        return AccountEmail.validated(object["email"])
    }
    func googleDefault(_ cookie: String) async throws -> String? {
        guard let body = try await read("https://accounts.google.com/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard", headers: ["Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded", "Origin": "https://www.google.com"], post: true) else { return nil }
        var data = body
        if let string = String(data: body, encoding: .utf8), string.hasPrefix(")]}'"), let newline = string.firstIndex(of: "\n") {
            data = Data(string[string.index(after: newline)...].utf8)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              root.first as? String == "gaia.l.a.r", root.count > 1,
              let accounts = root[1] as? [[Any]], let first = accounts.first, first.count > 3,
              first.first as? String == "gaia.l.a" else { return nil }
        // The usage request explicitly selects authuser=0, matching this first account.
        return AccountEmail.validated(first[3])
    }
}
