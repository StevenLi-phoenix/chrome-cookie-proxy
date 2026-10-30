import CommonCrypto
import Foundation

public enum DecryptFailure: Error, Equatable {
    case unsupportedPrefix
    case decryptFailed
    case hostHashMismatch
    case invalidUTF8
}

/// Chrome 在 macOS 上的 cookie 加密格式：`v10` + AES-128-CBC（PKCS7，IV 为 16 个 0x20），
/// 密钥是 PBKDF2-HMAC-SHA1(钥匙串里的 Safe Storage 密码, "saltysalt", 1003, 16)。
/// meta version >= 24 时明文前 32 字节是 SHA256(host_key)。
public enum CookieCrypto {
    static let salt = Array("saltysalt".utf8)
    static let iterations: UInt32 = 1003
    static let keyLength = 16
    static let iv = [UInt8](repeating: 0x20, count: 16)
    static let prefix = Array("v10".utf8)
    static let hostHashVersion = 24

    public static func deriveKey(password: Data) throws -> Data {
        var key = [UInt8](repeating: 0, count: keyLength)
        let status = password.withUnsafeBytes { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.baseAddress?.assumingMemoryBound(to: Int8.self), pw.count,
                salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), iterations,
                &key, key.count)
        }
        guard status == kCCSuccess else { throw ExportError.internalError("pbkdf2 status \(status)") }
        return Data(key)
    }

    public static func decrypt(_ encrypted: Data, hostKey: String, key: Data, metaVersion: Int) -> Result<String, DecryptFailure> {
        let bytes = [UInt8](encrypted)
        guard bytes.starts(with: prefix) else { return .failure(.unsupportedPrefix) }
        let cipher = Array(bytes.dropFirst(prefix.count))
        guard !cipher.isEmpty, cipher.count % kCCBlockSizeAES128 == 0, key.count == keyLength else {
            return .failure(.decryptFailed)
        }

        var plain = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let status = key.withUnsafeBytes { k in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress, k.count, iv, cipher, cipher.count, &plain, plain.count, &moved)
        }
        guard status == kCCSuccess else { return .failure(.decryptFailed) }
        var value = Array(plain[0..<moved])

        if metaVersion >= hostHashVersion {
            guard value.count >= 32, Array(value[0..<32]) == sha256(Array(hostKey.utf8)) else {
                return .failure(.hostHashMismatch)
            }
            value.removeFirst(32)
        }
        guard let text = String(data: Data(value), encoding: .utf8) else { return .failure(.invalidUTF8) }
        return .success(text)
    }

    static func sha256(_ input: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(input, CC_LONG(input.count), &digest)
        return digest
    }
}
