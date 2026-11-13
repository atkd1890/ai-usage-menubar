import Foundation

/// Cursor's Electron safeStorage envelope on macOS.
struct CursorTokenCodec {
    static let prefix = "cursor-safe-storage:v1:"
    static let keychainService = "Cursor Safe Storage"

    static func decode(_ value: String, password: String) throws -> String {
        guard value.hasPrefix(prefix),
              let payload = Data(base64Encoded: String(value.dropFirst(prefix.count))),
              let plaintext = try? ChromiumSafeStorageCodec.decrypt(payload, password: password),
              let token = String(data: plaintext, encoding: .utf8), !token.isEmpty else {
            throw failure
        }
        return token
    }

    static func encode(_ token: String, password: String) throws -> String {
        do {
            return prefix + (try ChromiumSafeStorageCodec.encrypt(Data(token.utf8), password: password)).base64EncodedString()
        } catch { throw failure }
    }

    static var failure: ProviderFailure {
        ProviderFailure(.storage, "Cursor credentials could not be decrypted. Open Cursor and try again.")
    }
}
