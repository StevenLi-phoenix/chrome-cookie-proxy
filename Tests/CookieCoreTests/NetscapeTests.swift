import XCTest
@testable import CookieCore

final class NetscapeTests: XCTestCase {
    func cookie(host: String = ".youtube.com", name: String = "N", value: String = "V", path: String = "/",
                expires: Int64 = 0, secure: Bool = false) -> ChromeCookie {
        ChromeCookie(hostKey: host, name: name, value: value, path: path, expiresUTC: expires, isSecure: secure)
    }

    func testExpiryConversion() {
        XCTAssertEqual(Netscape.unixExpiry(chromeMicros: 0), 0)
        // 独立计算：python3 -c "print((1893456000 + 11644473600) * 1000000)"
        XCTAssertEqual(Netscape.unixExpiry(chromeMicros: 13_537_929_600_000_000), 1_893_456_000)
        // 1970-01-01 对应 Chrome 纪元 11644473600 秒
        XCTAssertEqual(Netscape.unixExpiry(chromeMicros: 11_644_473_600_000_000), 0)
        XCTAssertEqual(Netscape.unixExpiry(chromeMicros: 11_644_473_601_000_000), 1)
        // 亚秒部分向下取整
        XCTAssertEqual(Netscape.unixExpiry(chromeMicros: 13_537_929_600_999_999), 1_893_456_000)
    }

    func testLineForDottedDomainSecure() {
        let line = Netscape.line(for: cookie(name: "LOGIN_INFO", value: "abc", expires: 13_537_929_600_000_000, secure: true))
        XCTAssertEqual(line, ".youtube.com\tTRUE\t/\tTRUE\t1893456000\tLOGIN_INFO\tabc")
    }

    func testLineForHostOnlyDomainNotSecure() {
        let line = Netscape.line(for: cookie(host: "accounts.google.com", name: "SID", value: "x", path: "/a", secure: false))
        XCTAssertEqual(line, "accounts.google.com\tFALSE\t/a\tFALSE\t0\tSID\tx")
    }

    func testSessionCookieKeepsZeroExpiry() {
        XCTAssertTrue(Netscape.line(for: cookie(expires: 0)).contains("\t0\tN\tV"))
    }

    func testNoHttpOnlyPrefix() {
        let out = Netscape.render([cookie()])
        XCTAssertFalse(out.contains("#HttpOnly_"))
    }

    func testRenderHeaderSortingAndTrailingNewline() {
        let out = Netscape.render([
            cookie(host: "accounts.google.com", name: "b"),
            cookie(host: ".youtube.com", name: "z"),
            cookie(host: ".youtube.com", name: "a", path: "/x"),
            cookie(host: ".youtube.com", name: "a", path: "/"),
            cookie(host: ".google.com", name: "m"),
        ])
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.first, "# Netscape HTTP Cookie File")
        XCTAssertEqual(lines.last, "")  // 以换行结尾
        let keys = lines.dropFirst().dropLast().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(keys.map { "\($0[0])|\($0[5])|\($0[2])" },
                       [".google.com|m|/", ".youtube.com|a|/", ".youtube.com|a|/x", ".youtube.com|z|/", "accounts.google.com|b|/"])
        XCTAssertTrue(keys.allSatisfy { $0.count == 7 })
    }

    func testRenderEmptyIsHeaderOnly() {
        XCTAssertEqual(Netscape.render([]), "# Netscape HTTP Cookie File\n")
    }

    func testSafeFieldRejectsControlCharacters() {
        XCTAssertTrue(Netscape.isSafe("plain value; with=stuff"))
        XCTAssertFalse(Netscape.isSafe("a\tb"))
        XCTAssertFalse(Netscape.isSafe("a\nb"))
        XCTAssertFalse(Netscape.isSafe("a\rb"))
    }
}
