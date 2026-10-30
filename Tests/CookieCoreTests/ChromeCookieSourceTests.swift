import SQLite3
import XCTest
@testable import CookieCore

final class ChromeCookieSourceTests: XCTestCase {
    let youtube = CookieSets.table["youtube"]!
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    let new = Date(timeIntervalSince1970: 1_800_000_000)

    /// Default（旧，schema 23）+ Profile 1（新，schema 24）
    func twoProfileChrome() throws -> (root: URL, work: URL) {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("chrome")
        let work = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let chrome = FixtureChrome(root: root)
        try chrome.addProfile("Default", metaVersion: 23, rows: Vectors.defaultRows, modified: old)
        try chrome.addProfile("Profile 1", metaVersion: 24, rows: Vectors.profile1Rows, modified: new)
        return (root, work)
    }

    func source(_ root: URL, work: URL, profile: String? = nil, passwords: ChromePasswordProvider = FixedPassword()) -> ChromeCookieSource {
        ChromeCookieSource(chromeRoot: root, profile: profile, passwords: passwords, workRoot: work)
    }

    func testExportsOnlyAllowlistedDomainsFromNewestProfile() throws {
        let (root, work) = try twoProfileChrome()
        let result = try source(root, work: work).export(suffixes: youtube)
        XCTAssertEqual(result.profile, "Profile 1")
        XCTAssertEqual(result.exported, 3)
        XCTAssertEqual(result.skipped, 3)  // BAD_HASH、V11_ONE、TAB_ONE
        let expected = [
            "# Netscape HTTP Cookie File",
            ".google.com\tTRUE\t/\tTRUE\t1893456000\t__Secure-3PSID\tpsid-secret-2",
            ".youtube.com\tTRUE\t/\tTRUE\t1893456000\tLOGIN_INFO\tlogin-info-secret-1",
            "accounts.google.com\tFALSE\t/a\tFALSE\t0\tPLAIN_ONE\tplain-value-5",
            "",
        ].joined(separator: "\n")
        XCTAssertEqual(result.body, expected)
    }

    func testOtherDomainsNeverAppear() throws {
        let (root, work) = try twoProfileChrome()
        let body = try source(root, work: work).export(suffixes: youtube).body
        for leaked in ["claude.ai", "sessionKey", "claude-session-3", "github.com", "user_session", "github-session-4",
                       "notyoutube", "NOT_MINE", "plain-value-9", "old-default-value", "BAD_HASH", "V11_ONE", "TAB_ONE"] {
            XCTAssertFalse(body.contains(leaked), leaked)
        }
    }

    func testExplicitProfileOverridesAutoSelection() throws {
        let (root, work) = try twoProfileChrome()
        let result = try source(root, work: work, profile: "Default").export(suffixes: youtube)
        XCTAssertEqual(result.profile, "Default")
        XCTAssertEqual(result.body, "# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t1893456000\tLOGIN_INFO\told-default-value\n")
    }

    func testKeychainTouchedOnceAndOnlyWhenNeeded() throws {
        let (root, work) = try twoProfileChrome()
        let counting = CountingPassword()
        _ = try source(root, work: work, passwords: counting).export(suffixes: youtube)
        XCTAssertEqual(counting.calls, 1)

        // 命中的行全是明文：不需要密码
        let plainOnly = try makeTempDir().appendingPathComponent("chrome")
        try FileManager.default.createDirectory(at: plainOnly, withIntermediateDirectories: false)
        try FixtureChrome(root: plainOnly).addProfile("Default", metaVersion: 24, rows: [
            FixtureRow(host: ".youtube.com", name: "A", value: "1"),
            FixtureRow(host: ".claude.ai", name: "B", encryptedHex: Vectors.claudeSession),
        ], modified: old)
        let untouched = CountingPassword()
        let r = try source(plainOnly, work: work, passwords: untouched).export(suffixes: youtube)
        XCTAssertEqual(untouched.calls, 0)
        XCTAssertEqual(r.exported, 1)
    }

    func testKeychainDeniedSurfaces() throws {
        let (root, work) = try twoProfileChrome()
        XCTAssertThrowsError(try source(root, work: work, passwords: DeniedPassword()).export(suffixes: youtube)) { error in
            XCTAssertEqual((error as? ExportError)?.code, "keychain_denied")
        }
    }

    func testNetworkCookiesLayoutAndPreference() throws {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("chrome")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let chrome = FixtureChrome(root: root)
        try chrome.addProfile("Default", cookiesPath: "Network/Cookies", metaVersion: 24, rows: Vectors.profile1Rows, modified: new)
        try chrome.addProfile("Profile 2", cookiesPath: "Cookies", metaVersion: 23, rows: Vectors.defaultRows, modified: old)
        let r = try source(root, work: base).export(suffixes: youtube)
        XCTAssertEqual(r.profile, "Default")
        XCTAssertEqual(r.exported, 3)
    }

    func testOnlyDefaultAndProfileStarDirectoriesAreCandidates() throws {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("chrome")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let chrome = FixtureChrome(root: root)
        try chrome.addProfile("Default", metaVersion: 23, rows: Vectors.defaultRows, modified: old)
        try chrome.addProfile("Guest Profile", metaVersion: 23, rows: [], modified: new)
        try chrome.addProfile("System Profile", metaVersion: 23, rows: [], modified: new)
        try chrome.addProfile("Profile", metaVersion: 23, rows: [], modified: new)  // 没有空格，不是 Profile *
        XCTAssertEqual(try source(root, work: base).export(suffixes: youtube).profile, "Default")
    }

    func testNoProfile() throws {
        let base = try makeTempDir()
        let empty = base.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        for (root, profile) in [(empty, nil), (base.appendingPathComponent("missing"), nil), (empty, "Default"), (empty, "../x")] as [(URL, String?)] {
            XCTAssertThrowsError(try source(root, work: base, profile: profile).export(suffixes: youtube)) { error in
                XCTAssertEqual((error as? ExportError)?.code, "no_profile")
            }
        }
    }

    func testCorruptDatabase() throws {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("chrome/Default")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: root.appendingPathComponent("Cookies"))
        XCTAssertThrowsError(try source(base.appendingPathComponent("chrome"), work: base).export(suffixes: youtube)) { error in
            XCTAssertEqual((error as? ExportError)?.code, "cookies_db_unreadable")
        }
    }

    func testMissingMetaVersionMeansNoHashPrefix() throws {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("chrome")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FixtureChrome(root: root).addProfile("Default", metaVersion: nil, rows: Vectors.defaultRows, modified: old)
        let r = try source(root, work: base).export(suffixes: youtube)
        XCTAssertEqual(r.exported, 1)
        XCTAssertTrue(r.body.hasSuffix("LOGIN_INFO\told-default-value\n"))
    }

    func testChromeFilesAreUntouchedAndWorkDirIsCleaned() throws {
        let (root, work) = try twoProfileChrome()
        let file = root.appendingPathComponent("Profile 1/Cookies")
        let before = try Data(contentsOf: file)
        let listing = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Profile 1").path).sorted()
        _ = try source(root, work: work).export(suffixes: youtube)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Profile 1").path).sorted(), listing)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }

    func testWorkDirIsCleanedOnFailureToo() throws {
        let base = try makeTempDir()
        let work = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = base.appendingPathComponent("chrome/Default")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: root.appendingPathComponent("Cookies"))
        _ = try? source(base.appendingPathComponent("chrome"), work: work).export(suffixes: youtube)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }

    func testRowsStillInWalAreIncluded() throws {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("chrome")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = try FixtureChrome(root: root).addProfile("Default", metaVersion: 24, rows: [
            FixtureRow(host: ".youtube.com", name: "IN_MAIN", value: "main"),
        ], modified: old)

        // 切到 WAL，再写一行并保持连接（不 checkpoint）：这一行只在 Cookies-wal 里
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            INSERT INTO cookies(creation_utc, host_key, name, value, encrypted_value, path, expires_utc, is_secure)
            VALUES(99, '.youtube.com', 'IN_WAL', 'wal', x'', '/', 0, 0)
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + "-wal"))

        let r = try source(root, work: base).export(suffixes: youtube)
        XCTAssertEqual(r.exported, 2)
        XCTAssertTrue(r.body.contains("IN_MAIN\tmain"))
        XCTAssertTrue(r.body.contains("IN_WAL\twal"))
    }
}
