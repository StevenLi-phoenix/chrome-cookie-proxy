import Foundation

/// 真正的导出：选 profile -> 复制并读库（按白名单过滤）-> 解密 -> Netscape。
public struct ChromeCookieSource: CookieSource {
    let chromeRoot: URL
    let profile: String?
    let passwords: ChromePasswordProvider
    let workRoot: URL

    public init(chromeRoot: URL, profile: String?, passwords: ChromePasswordProvider,
                workRoot: URL = FileManager.default.temporaryDirectory) {
        self.chromeRoot = chromeRoot
        self.profile = profile
        self.passwords = passwords
        self.workRoot = workRoot
    }

    public func export(suffixes: [String]) throws -> ExportResult {
        let selected = try ProfileLocator.select(chromeRoot: chromeRoot, profile: profile)
        let contents = try CookieDatabase.read(cookiesFile: selected.cookiesFile, workRoot: workRoot) {
            CookieSets.matches(hostKey: $0, suffixes: suffixes)
        }

        // 只有真的遇到加密值才碰钥匙串，且一次导出只取一次。
        var key: Data?
        var cookies: [ChromeCookie] = []
        var skipped = 0
        for row in contents.rows {
            let value: String
            if row.encryptedValue.isEmpty {
                value = row.value
            } else {
                if key == nil { key = try deriveKey() }
                switch CookieCrypto.decrypt(row.encryptedValue, hostKey: row.hostKey, key: key!, metaVersion: contents.metaVersion) {
                case .success(let plain): value = plain
                case .failure: skipped += 1; continue
                }
            }
            guard [row.hostKey, row.name, row.path, value].allSatisfy(Netscape.isSafe) else { skipped += 1; continue }
            cookies.append(ChromeCookie(hostKey: row.hostKey, name: row.name, value: value, path: row.path,
                                        expiresUTC: row.expiresUTC, isSecure: row.isSecure))
        }
        return ExportResult(body: Netscape.render(cookies), exported: cookies.count, skipped: skipped, profile: selected.name)
    }

    private func deriveKey() throws -> Data {
        let password: Data
        do {
            password = try passwords.password()
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.keychainDenied("\(type(of: error))")
        }
        return try CookieCrypto.deriveKey(password: password)
    }
}
