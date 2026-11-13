import Foundation

struct CopilotToken: Equatable, Sendable {
    let value: String
}

struct CopilotAuthStore: Sendable {
    static let editorAppsPath = "~/.config/github-copilot/apps.json"
    static let editorHostsPath = "~/.config/github-copilot/hosts.json"
    static let ghHostsPath = "~/.config/gh/hosts.yml"
    static let ghKeychainService = "gh:github.com"

    let files: TextFileAccessing
    let keychain: KeychainAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor()
    ) {
        self.files = files
        self.keychain = keychain
    }

    func loadToken() -> CopilotToken? {
        loadFromEditorConfig() ?? loadFallbackTokens().first
    }

    func loadFromEditorConfig() -> CopilotToken? {
        loadEditorTokens().first
    }

    func loadEditorTokens() -> [CopilotToken] {
        var tokens: [CopilotToken] = []
        for path in [Self.editorAppsPath, Self.editorHostsPath] {
            guard files.exists(path), let text = try? files.readText(path) else {
                continue
            }
            tokens += Self.oauthTokens(fromEditorJSON: text).map { CopilotToken(value: $0) }
        }
        return tokens
    }

    /// Read Keychain only after editor credentials have been rejected or are absent.
    func loadFallbackTokens() -> [CopilotToken] {
        [loadFromGitHubCLIFile(), loadFromKeychain()].compactMap { $0 }
    }

    func loadFromGitHubCLIFile() -> CopilotToken? {
        guard files.exists(Self.ghHostsPath),
              let text = try? files.readText(Self.ghHostsPath),
              let token = Self.yamlValue(text, key: "oauth_token") else {
            return nil
        }
        return CopilotToken(value: token)
    }

    func loadFromKeychain() -> CopilotToken? {
        guard
            let raw = try? keychain.readGenericPassword(
                service: Self.ghKeychainService
            ),
            let token = Self.unwrapGoKeyring(raw)
        else {
            return nil
        }
        return CopilotToken(value: token)
    }

    static func oauthToken(fromEditorJSON text: String) -> String? {
        oauthTokens(fromEditorJSON: text).first
    }

    static func oauthTokens(fromEditorJSON text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return object.keys.sorted().compactMap { host in
            guard host == "github.com" || host.hasPrefix("github.com:"),
                  let value = object[host] as? [String: Any],
                  let raw = value["oauth_token"] as? String else { return nil }
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }
    }

    static func yamlValue(
        _ text: String,
        key: String,
        host: String = "github.com"
    ) -> String? {
        let keyPrefix = "\(key):"
        let hostHeader = "\(host):"
        var isInHost = false

        for line in text.split(whereSeparator: \.isNewline) {
            if let first = line.first, !first.isWhitespace {
                isInHost = line
                    .trimmingCharacters(in: .whitespaces)
                    .hasPrefix(hostHeader)
                continue
            }
            guard isInHost else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(keyPrefix) else { continue }
            let value = trimmed
                .dropFirst(keyPrefix.count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(
                    in: CharacterSet(charactersIn: "\"'")
                )
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func unwrapGoKeyring(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if trimmed.hasPrefix(prefix) {
            let encoded = String(trimmed.dropFirst(prefix.count))
            guard let data = Data(base64Encoded: encoded),
                  let decoded = String(data: data, encoding: .utf8) else {
                return nil
            }
            let token = decoded.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return token.isEmpty ? nil : token
        }
        return trimmed.isEmpty ? nil : trimmed
    }
}
