import Foundation
import CommonCrypto

/// macOS Chromium OSCrypt v10: PBKDF2-SHA1 and AES-128-CBC.
/// Contract: chromium/components/os_crypt/sync/os_crypt_mac.mm.
enum ChromiumSafeStorageCodec {
    enum CodecError: Error { case invalidData }

    static func decrypt(_ payload: Data, password: String) throws -> Data {
        guard payload.starts(with: Data("v10".utf8)), payload.count > 3,
              (payload.count - 3) % kCCBlockSizeAES128 == 0 else {
            throw CodecError.invalidData
        }
        return try crypt(Data(payload.dropFirst(3)), password: password, operation: CCOperation(kCCDecrypt))
    }

    static func encrypt(_ plaintext: Data, password: String) throws -> Data {
        Data("v10".utf8) + (try crypt(plaintext, password: password, operation: CCOperation(kCCEncrypt)))
    }

    private static func crypt(_ input: Data, password: String, operation: CCOperation) throws -> Data {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derivation = password.withCString { passwordBytes in
            salt.withUnsafeBufferPointer { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes,
                    password.utf8.count, saltBytes.baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
            }
        }
        guard derivation == kCCSuccess else { throw CodecError.invalidData }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = input.withUnsafeBytes { bytes in
            CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                key, key.count, iv, bytes.baseAddress, input.count, &output, capacity, &written)
        }
        guard status == kCCSuccess else { throw CodecError.invalidData }
        return Data(output.prefix(written))
    }

}
