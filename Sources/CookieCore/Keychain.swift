import Foundation
import Security

/// 从登录钥匙串读 “Chrome Safe Storage”。第一次访问时 macOS 会弹授权框，选“始终允许”之后不再询问。
public struct KeychainPasswordProvider: ChromePasswordProvider {
    public init() {}

    static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }

    public func password() throws -> Data {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(Self.query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw ExportError.keychainDenied("OSStatus \(status)")
        }
        return data
    }
}
