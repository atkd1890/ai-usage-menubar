import CryptoKit
import Foundation

struct GeminiNativeCredential: Sendable {
    let refreshToken: String
    let clientID: String
    let accountLabel: String?
    var fingerprint: Data {
        Data(SHA256.hash(data: Data((clientID + "\u{0}" + refreshToken).utf8)))
    }
}
struct GeminiNativeOAuthClient: Sendable {
    let clientID: String
    let clientSecret: String
}

struct GeminiNativeAuthStore: Sendable {
    static let root = "~/Library/Application Support/com.google.GeminiMacOS"
    static let binaryPath = "/Applications/Gemini.app/Contents/MacOS/Gemini"
    static let accessKey = "geminiNativeAccessAllowed.v1"
    let readData: @Sendable (String) throws -> Data
    let readKeyStore: @Sendable () throws -> Data
    let allowNativeAccess: Bool?

    init(allowNativeAccess: Bool? = nil,
         readData: @escaping @Sendable (String) throws -> Data = {
             try Data(contentsOf: URL(fileURLWithPath: expandHome($0)), options: .mappedIfSafe)
         },
         readKeyStore: @escaping @Sendable () throws -> Data = Self.loadKeyStore) {
        self.allowNativeAccess = allowNativeAccess
        self.readData = readData
        self.readKeyStore = readKeyStore
    }

    func load() throws -> GeminiNativeCredential {
        guard allowNativeAccess ?? UserDefaults.standard.bool(forKey: Self.accessKey) else {
            throw ProviderFailure(.authentication, "Enable ‘Use Gemini app login’ in Settings to read native usage.")
        }
        let config: Data
        do { config = try readData(Self.root + "/account_config") }
        catch { throw Self.signInRequired }
        guard let fields = try? GeminiProtobuf.fields(config),
              let activeData = fields.first(where: { $0.number == 4 })?.bytes,
              let active = String(data: activeData, encoding: .utf8),
              active.range(of: #"^user[0-9]+$"#, options: .regularExpression) != nil else {
            throw Self.signInRequired
        }
        do {
            let encrypted = try readData(Self.root + "/Data/" + active + "/auth")
            let keyStore = try readKeyStore()
            return try Self.decryptCredential(encrypted, keyStore: keyStore)
        } catch let failure as ProviderFailure { throw failure }
        catch { throw Self.storageFailure }
    }

    func loadClient(for clientID: String) throws -> GeminiNativeOAuthClient {
        do { return try Self.clientConfiguration(in: readData(Self.binaryPath), clientID: clientID) }
        catch { throw ProviderFailure(.storage, "Gemini app OAuth configuration changed. Update AI Usage.") }
    }

    static func decryptCredential(_ blob: Data, keyStore: Data) throws -> GeminiNativeCredential {
        let magic = Data([0x2e, 0xba, 0xfe, 0xca, 0x2e, 0xba, 0xfe, 0xca])
        guard blob.count >= 12, blob.starts(with: magic) else { throw storageFailure }
        let headerLength = (0..<4).reduce(0) { $0 | Int(blob[8 + $1]) << ($1 * 8) }
        guard headerLength > 0, headerLength <= blob.count - 12 else { throw storageFailure }
        let header = try GeminiProtobuf.fields(Data(blob[12..<12 + headerLength]))
        let payload = Data(blob.dropFirst(12 + headerLength))
        guard let keyID = header.first(where: { $0.number == 1 })?.integer, keyID == 1,
              let version = header.first(where: { $0.number == 2 })?.integer,
              header.first(where: { $0.number == 3 })?.integer == 1,
              let nonce = header.first(where: { $0.number == 4 })?.bytes, nonce.count == 12,
              header.first(where: { $0.number == 5 })?.integer == UInt64(payload.count), payload.count >= 16 else {
            throw storageFailure
        }
        var matching: [Data] = []
        for entry in try GeminiProtobuf.fields(keyStore) where entry.number == 2 {
            guard let bytes = entry.bytes else { continue }
            let key = try GeminiProtobuf.fields(bytes)
            if key.first(where: { $0.number == 1 })?.integer == keyID,
               key.first(where: { $0.number == 2 })?.integer == version,
               let material = key.first(where: { $0.number == 4 })?.bytes {
                matching.append(material)
            }
        }
        guard matching.count == 1, let material = matching.first, material.count == 32 else { throw storageFailure }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: payload.dropLast(16), tag: payload.suffix(16))
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: material))
        let fields = try GeminiProtobuf.fields(plaintext)
        guard let refreshData = fields.first(where: { $0.number == 4 })?.bytes,
              let refresh = String(data: refreshData, encoding: .utf8), !refresh.isEmpty,
              let idData = fields.first(where: { $0.number == 8 })?.bytes,
              let idToken = String(data: idData, encoding: .utf8),
              let part = idToken.split(separator: ".").dropFirst().first,
              let claimsData = ProviderParsing.base64URLData(String(part)),
              let claims = try? JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              let clientID = claims["aud"] as? String,
              clientID.hasSuffix(".apps.googleusercontent.com"), clientID.count <= 256 else {
            throw storageFailure
        }
        let email = fields.first(where: { $0.number == 2 })?.bytes.flatMap { String(data: $0, encoding: .utf8) }
        return GeminiNativeCredential(refreshToken: refresh, clientID: clientID, accountLabel: email)
    }

    /// Reads the installed app's public OAuth config instead of copying it into this repository.
    /// Gemini 1.135 ships its 35-byte client secret XOR-encoded with 0x5a.
    static func clientConfiguration(in binary: Data, clientID: String) throws -> GeminiNativeOAuthClient {
        guard binary.range(of: Data(clientID.utf8)) != nil else { throw storageFailure }
        let marker = Data("GOCSPX-".utf8.map { $0 ^ 0x5a })
        guard let range = binary.range(of: marker),
              binary.count - range.lowerBound >= 35,
              binary.range(of: marker, in: range.upperBound..<binary.endIndex) == nil else { throw storageFailure }
        let decoded = binary[range.lowerBound..<range.lowerBound + 35].map { $0 ^ 0x5a }
        guard let secret = String(bytes: decoded, encoding: .utf8),
              secret.range(of: #"^GOCSPX-[A-Za-z0-9_-]{28}$"#, options: .regularExpression) != nil else {
            throw storageFailure
        }
        return GeminiNativeOAuthClient(clientID: clientID, clientSecret: secret)
    }

    static func loadKeyStore() throws -> Data {
        let result = try SystemProcessRunner().run(executable: "/usr/bin/security", arguments: [
            "find-generic-password", "-s", "Gemini Safe Storage", "-a", "Gemini Keys", "-w"
        ], environment: [:], timeout: 30)
        guard result.succeeded else {
            throw ProviderFailure(.storage, "Allow Gemini Safe Storage access in Keychain to read native usage.")
        }
        return try GeminiProtobuf.hexData(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    static var signInRequired: ProviderFailure {
        ProviderFailure(.authentication, "Open the Gemini app and sign in, then refresh.")
    }
    static var storageFailure: ProviderFailure {
        ProviderFailure(.storage, "Gemini app credentials could not be read or decrypted.")
    }
}
