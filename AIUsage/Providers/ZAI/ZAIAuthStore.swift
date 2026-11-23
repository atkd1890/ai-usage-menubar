import CryptoKit
import Foundation

struct ZAICredential: Sendable {
    let token: String
    let zcodeToken: String?
    let email: String?
    let source: String
    let startHeaders: [String: String]
    init(token: String, zcodeToken: String?, email: String?, source: String, startHeaders: [String: String] = [:]) {
        self.token = token; self.zcodeToken = zcodeToken; self.email = ZAIAuthStore.unmaskedEmail(email); self.source = source; self.startHeaders = startHeaders
    }
}

/// Reads the selected login without rotating or modifying its credentials.
struct ZAIAuthStore: Sendable {
    static let browserKeys: Set<String> = ["z-ai-open-platform-token-production", "platform-user-info"]
    let home: String
    let key: @Sendable (String) throws -> String?

    init(home: String = NSHomeDirectory(), key: @escaping @Sendable (String) throws -> String? = Self.readKey) {
        self.home = home; self.key = key
    }

    func load(_ method: ProviderLoginMethod) throws -> ZAICredential {
        if method == .desktop {
            let file = URL(fileURLWithPath: home).appendingPathComponent(".zcode/v2/credentials.json").resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw ProviderFailure(.authentication, "Sign in to Z.ai in ZCode desktop.")
            }
            do {
                let source = try String(contentsOf: file.deletingLastPathComponent().appendingPathComponent("credential-source"), encoding: .utf8)
                guard source.trimmingCharacters(in: .whitespacesAndNewlines) == "os" else { throw Failure.unsupported }
                let data = try Data(contentsOf: file)
                guard data.count <= 2_000_000,
                      let root = try JSONSerialization.jsonObject(with: data) as? [String: String],
                      let storedKey = try key(Self.hash(file.path)), let rawKey = Self.base64(storedKey), rawKey.count == 32 else { throw Failure.unsupported }
                func value(_ name: String) throws -> String? {
                    guard let value = root[name] else { return nil }
                    return try Self.decrypt(value, key: rawKey)
                }
                guard try value("oauth:active_provider") == "zai" else {
                    throw ProviderFailure(.authentication, "Select the Z.ai account in ZCode desktop.")
                }
                guard let token = try value("oauth:zai:access_token"), !token.isEmpty else {
                    throw ProviderFailure(.authentication, "Sign in to Z.ai in ZCode desktop.")
                }
                let profile = try value("oauth:zai:user_info")
                return ZAICredential(token: token, zcodeToken: try value("zcodejwttoken"),
                    email: Self.email(profile), source: "ZCode desktop", startHeaders: Self.startHeaders(home: home))
            } catch let failure as ProviderFailure { throw failure }
            catch { throw ProviderFailure(.storage, "ZCode login could not be read or decrypted. Check its Keychain access.") }
        }
        guard method == .edge || method == .chrome else {
            throw ProviderFailure(.storage, "Unsupported Z.ai login method.")
        }
        let label = method == .edge ? "Edge Default" : "Chrome Default"
        let product = method == .edge ? "Microsoft Edge" : "Google/Chrome"
        let cookiesPath = home + "/Library/Application Support/" + product + "/Default/Cookies"
        let selectedAccess = BrowserDatabaseAccess.start(path: cookiesPath)
        defer { selectedAccess?.stopAccessingSecurityScopedResource() }
        let directory = URL(fileURLWithPath: home + "/Library/Application Support/" + product + "/Default/Local Storage/leveldb")
        let values: [String: String]
        do {
            // Chromium may compact between manifest and table reads. Retry one fresh read; never copy its DB.
            do { values = try ScopedLocalStorageReader().read(directory: directory, origin: "https://z.ai", names: Self.browserKeys) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                values = try ScopedLocalStorageReader().read(directory: directory, origin: "https://z.ai", names: Self.browserKeys)
            }
        } catch {
            let nsError = error as NSError
            let permissionDenied = (nsError.domain == NSPOSIXErrorDomain && [Int(POSIXError.Code.EPERM.rawValue), Int(POSIXError.Code.EACCES.rawValue)].contains(nsError.code)) ||
                (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError)
            throw ProviderFailure(.storage, permissionDenied
                ? "macOS denied access to \(label) data. Allow AI Usage access in Privacy & Security, then refresh."
                : "Z.ai login storage in \(label) could not be read.")
        }
        guard let token = values["z-ai-open-platform-token-production"], !token.isEmpty else {
            throw ProviderFailure(.authentication, "Sign in at z.ai/model-api in \(label). Chat login is separate.")
        }
        return ZAICredential(token: token, zcodeToken: nil, email: Self.email(values["platform-user-info"]), source: label)
    }

    static func startHeaders(home: String) -> [String: String] {
        let path = URL(fileURLWithPath: home).appendingPathComponent(".zcode/v2/telemetry-state.json")
        guard let data = try? Data(contentsOf: path), data.count < 1_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = object["deviceMid"] as? String, UUID(uuidString: device) != nil else { return [:] }
        let version = ["/Applications/ZCode.app", home + "/Applications/ZCode.app"].compactMap { Bundle(path: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }.first ?? "3.18.2"
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return [:] }
        #if arch(arm64)
        let platform = "darwin-arm64"
        #else
        let platform = "darwin-x64"
        #endif
        return ["X-Device-Mid": device, "X-ZCode-App-Version": version, "X-Platform": platform,
                "HTTP-Referer": "https://zcode.z.ai", "User-Agent": "ZCode/" + version, "X-Title": "Z Code@electron",
                "X-Client-Language": "en-US", "X-Client-Timezone": TimeZone.current.identifier, "X-Os-Category": "macos"]
    }

    enum Failure: Error { case unsupported }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func base64(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }
    static func decrypt(_ text: String, key: Data) throws -> String {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        let keyID = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined().prefix(24)
        guard key.count == 32, parts.count == 5, parts[0] == "enc", parts[1] == "v2", parts[2] == "os", parts[3] == keyID else { throw Failure.unsupported }
        let payload = parts[4].split(separator: ".", omittingEmptySubsequences: false)
        guard payload.count == 3, let nonce = base64(String(payload[0])), nonce.count == 12,
              let tag = base64(String(payload[1])), tag.count == 16, let ciphertext = base64(String(payload[2])) else { throw Failure.unsupported }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
        guard let result = String(data: try AES.GCM.open(box, using: SymmetricKey(data: key)), encoding: .utf8) else { throw Failure.unsupported }
        return result
    }
    static func email(_ json: String?) -> String? {
        guard let json, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        return unmaskedEmail(object["email"])
    }
    static func unmaskedEmail(_ value: Any?) -> String? {
        guard let email = AccountEmail.validated(value), !email.contains("*"), !email.contains("•"), !email.contains("…") else { return nil }
        return email
    }
    private static func readKey(account: String) throws -> String? {
        try SecurityKeychainAccessor().readGenericPassword(service: "ZCode Credential Encryption", account: account)
    }
}
