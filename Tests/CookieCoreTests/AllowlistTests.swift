import XCTest
@testable import CookieCore

final class AllowlistTests: XCTestCase {
    let suffixes = CookieSets.table["youtube"]!

    func testYoutubeSetIsCompiledIn() {
        XCTAssertEqual(suffixes, ["youtube.com", "google.com"])
        XCTAssertNil(CookieSets.table["github"])
    }

    func testMatches() {
        for host in [".youtube.com", "youtube.com", "www.youtube.com", ".google.com", "google.com",
                     "accounts.google.com", ".accounts.google.com", "m.youtube.com", "Accounts.Google.COM"] {
            XCTAssertTrue(CookieSets.matches(hostKey: host, suffixes: suffixes), host)
        }
    }

    func testDoesNotMatch() {
        for host in ["notyoutube.com", ".notyoutube.com", "claude.ai", ".claude.ai", "github.com",
                     "google.com.evil.io", "youtube.com.evil.io", "evilgoogle.com", "youtube.co",
                     "", ".", "..youtube.com", "xgoogle.com", "google.com."] {
            XCTAssertFalse(CookieSets.matches(hostKey: host, suffixes: suffixes), host)
        }
    }

    func testEmptySuffixListMatchesNothing() {
        XCTAssertFalse(CookieSets.matches(hostKey: ".youtube.com", suffixes: []))
    }
}
