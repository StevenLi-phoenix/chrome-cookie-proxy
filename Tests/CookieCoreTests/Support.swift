import Foundation
import SQLite3
import XCTest
@testable import CookieCore

extension Data {
    init(hex: String) {
        precondition(hex.count % 2 == 0, "odd hex length")
        var bytes = [UInt8]()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            bytes.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// 注入的“钥匙串”：密码固定为 Chrome 在没有钥匙串时用的 `peanuts`，测试不碰真实钥匙串。
struct FixedPassword: ChromePasswordProvider {
    var value = "peanuts"
    func password() throws -> Data { Data(value.utf8) }
}

struct DeniedPassword: ChromePasswordProvider {
    func password() throws -> Data { throw ExportError.keychainDenied("OSStatus -25293") }
}

/// 计数用：确认某些路径不会碰钥匙串。
final class CountingPassword: ChromePasswordProvider, @unchecked Sendable {
    private(set) var calls = 0
    func password() throws -> Data { calls += 1; return Data("peanuts".utf8) }
}

extension XCTestCase {
    /// 路径要短：unix socket 的 sun_path 在 macOS 上只有 104 字节。
    func makeTempDir(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let suffix = String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("ccp-\(suffix)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

struct FixtureRow {
    var host: String
    var name: String
    var value: String = ""
    var encryptedHex: String = ""
    var path: String = "/"
    var expiresUTC: Int64 = 0
    var secure: Bool = false
}

/// 假的 Chrome 根目录：每个 profile 一个用 SQLite C API 建出来的 Cookies 库。
struct FixtureChrome {
    let root: URL

    init(root: URL) { self.root = root }

    /// - cookiesPath: 相对 profile 目录的位置，旧布局 `Cookies`，新布局 `Network/Cookies`
    @discardableResult
    func addProfile(_ name: String, cookiesPath: String = "Cookies", metaVersion: Int?, rows: [FixtureRow],
                    modified: Date) throws -> URL {
        let file = root.appendingPathComponent(name).appendingPathComponent(cookiesPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.writeDatabase(at: file, metaVersion: metaVersion, rows: rows)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        return file
    }

    static func writeDatabase(at url: URL, metaVersion: Int?, rows: [FixtureRow]) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 1)
        }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
        try exec("CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)")
        if let v = metaVersion { try exec("INSERT INTO meta(key, value) VALUES('version', '\(v)')") }
        try exec("""
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL DEFAULT '',
              name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL DEFAULT x'', path TEXT NOT NULL,
              expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL DEFAULT 0,
              last_access_utc INTEGER NOT NULL DEFAULT 0, has_expires INTEGER NOT NULL DEFAULT 1,
              is_persistent INTEGER NOT NULL DEFAULT 1, priority INTEGER NOT NULL DEFAULT 1, samesite INTEGER NOT NULL DEFAULT -1)
            """)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, r) in rows.enumerated() {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO cookies(creation_utc, host_key, name, value, encrypted_value, path, expires_utc, is_secure) VALUES(?,?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw NSError(domain: "fixture", code: 3) }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(i + 1))
            sqlite3_bind_text(stmt, 2, r.host, -1, transient)
            sqlite3_bind_text(stmt, 3, r.name, -1, transient)
            sqlite3_bind_text(stmt, 4, r.value, -1, transient)
            let blob = Data(hex: r.encryptedHex)
            blob.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, 5, $0.baseAddress, Int32(blob.count), transient) }
            sqlite3_bind_text(stmt, 6, r.path, -1, transient)
            sqlite3_bind_int64(stmt, 7, r.expiresUTC)
            sqlite3_bind_int(stmt, 8, r.secure ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw NSError(domain: "fixture", code: 4) }
        }
    }
}

/// 以下密文全部由 openssl 生成（key = PBKDF2("peanuts")，IV = 16 × 0x20），明文为
/// sha256(host_key) + 值（schema 版本 24）。
enum Vectors {
    static let futureExpiry: Int64 = 13_537_929_600_000_000  // unix 1893456000
    static func v10(_ hex: String) -> String { "763130" + hex }  // "v10"

    // .youtube.com / login-info-secret-1
    static let loginInfo = v10("dfedf6a25de951793acf97b7e0577316f5009863e773f7845c5b1d94c4dd6630ec0c37e7c4cbfa19ded4992bed2bfc11a46ea6cccc62ed3f723fa650b73bc74a")
    // .google.com / psid-secret-2
    static let psid = v10("c465b74c8b126d743669e3f98cad939440ef90c07cf4024d93e96b9d66ad111fe5811d7464fe3b530f25e2ae9808eb14")
    // .claude.ai / claude-session-3
    static let claudeSession = v10("ab00c3632bb298d7d20a35189dc998ff7cd0b2b341f1596100d3c7e45900e88c6cb339b859a4c82b6a53703447512dcd021bf785f8092ab602ad600e798c1f5a")
    // github.com / github-session-4
    static let githubSession = v10("2725fc0dc9688af8204a39881d3cd12f9a839c903dfb529486dba6d0a4a201794be0821c4e4243db4cd99d92422f9129ee7dae85aeef09f564376cbdd8bec55d")
    // 主机是 .youtube.com，但哈希前缀是 sha256(".other.com") + "x"
    static let wrongHostHash = v10("c661929f0e26b883c6caafed2ccca72d201354b35ebfd4d4b53ff663437e244a91ac632f86a54d9e54e9293b555bbdd0")
    // schema 23（无哈希前缀）：明文 "old-default-value"
    static let oldDefault = v10("c7d4e0597502d3b0530b0f614a3b852ba9f7afb780bd6ff287373c4e7b3379c3")
    // v11 前缀（Linux 的格式），应被跳过
    static let v11 = "763131" + "8690a7cb3c7871d1a16024469ce35b43"

    /// Profile 1（schema 24，较新）
    static let profile1Rows: [FixtureRow] = [
        FixtureRow(host: ".youtube.com", name: "LOGIN_INFO", encryptedHex: loginInfo, path: "/", expiresUTC: futureExpiry, secure: true),
        FixtureRow(host: ".google.com", name: "__Secure-3PSID", encryptedHex: psid, path: "/", expiresUTC: futureExpiry, secure: true),
        FixtureRow(host: ".claude.ai", name: "sessionKey", encryptedHex: claudeSession, path: "/", expiresUTC: futureExpiry, secure: true),
        FixtureRow(host: "github.com", name: "user_session", encryptedHex: githubSession, path: "/", expiresUTC: futureExpiry, secure: true),
        FixtureRow(host: "accounts.google.com", name: "PLAIN_ONE", value: "plain-value-5", path: "/a", expiresUTC: 0, secure: false),
        FixtureRow(host: ".youtube.com", name: "BAD_HASH", encryptedHex: wrongHostHash),
        FixtureRow(host: ".youtube.com", name: "V11_ONE", encryptedHex: v11),
        FixtureRow(host: ".youtube.com", name: "TAB_ONE", value: "a\tb"),
        FixtureRow(host: "notyoutube.com", name: "NOT_MINE", value: "plain-value-9"),
    ]

    /// Default（schema 23，较旧）
    static let defaultRows: [FixtureRow] = [
        FixtureRow(host: ".youtube.com", name: "LOGIN_INFO", encryptedHex: oldDefault, path: "/", expiresUTC: futureExpiry, secure: true),
    ]
}
