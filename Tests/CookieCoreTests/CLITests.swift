import XCTest
@testable import CookieCore

final class CLITests: XCTestCase {
    let home = "/Users/tester"

    func testServeDefaults() throws {
        XCTAssertEqual(try CLI.parse(["serve"], home: home), .serve(ServeOptions(
            socketPath: "/Users/tester/.local/state/chrome-cookie-proxy/proxy.sock",
            chromeRoot: "/Users/tester/Library/Application Support/Google/Chrome",
            profile: nil)))
    }

    func testServeFlags() throws {
        let cmd = try CLI.parse(["serve", "--socket", "/tmp/a/b.sock", "--chrome-root", "/c", "--profile", "Profile 1"], home: home)
        XCTAssertEqual(cmd, .serve(ServeOptions(socketPath: "/tmp/a/b.sock", chromeRoot: "/c", profile: "Profile 1")))
    }

    func testAllowUIDIsRepeatable() throws {
        let cmd = try CLI.parse(["serve", "--allow-uid", "502", "--allow-uid", "503", "--allow-uid", "502"], home: home)
        guard case .serve(let options) = cmd else { return XCTFail("\(cmd)") }
        XCTAssertEqual(options.allowUIDs, [502, 503])  // 去重、保持出现顺序
        XCTAssertNil(options.socketMode)
    }

    func testAllowUIDRejectsNonNumbers() {
        for bad in ["", "abc", "-1", "5.5", "4294967296", "0x1f5", " 502"] {
            XCTAssertThrowsError(try CLI.parse(["serve", "--allow-uid", bad], home: home), bad)
        }
        XCTAssertThrowsError(try CLI.parse(["serve", "--allow-uid"], home: home))
    }

    func testSocketModeParsesOctal() throws {
        for (text, expected) in [("0666", 0o666), ("666", 0o666), ("0600", 0o600), ("660", 0o660)] as [(String, UInt16)] {
            guard case .serve(let o) = try CLI.parse(["serve", "--socket-mode", text], home: home) else { return XCTFail(text) }
            XCTAssertEqual(o.socketMode, expected, text)
        }
    }

    func testSocketModeRejectsUnsafeValues() {
        // 属主必须能读写；不接受 setuid/sticky 位、非八进制、超范围
        for bad in ["", "0444", "0400", "0200", "0000", "4600", "1777", "0888", "abc", "-600", "07777"] {
            XCTAssertThrowsError(try CLI.parse(["serve", "--socket-mode", bad], home: home), bad)
        }
    }

    func testNewFlagsLeaveDefaultsUntouched() throws {
        let cmd = try CLI.parse(["serve", "--socket", "/s/x.sock"], home: home)
        guard case .serve(let o) = cmd else { return XCTFail() }
        XCTAssertEqual(o.allowUIDs, [])
        XCTAssertNil(o.socketMode)
    }

    func testVersion() throws {
        XCTAssertEqual(try CLI.parse(["version"], home: home), .version)
        XCTAssertEqual(try CLI.parse(["--version"], home: home), .version)
        XCTAssertThrowsError(try CLI.parse(["version", "extra"], home: home))
    }

    func testHelpAndErrors() {
        XCTAssertEqual(try CLI.parse(["--help"], home: home), .help)
        XCTAssertEqual(try CLI.parse(["help"], home: home), .help)
        for bad in [[], ["bogus"], ["serve", "--nope"], ["serve", "--socket"], ["serve", "--profile", "../x"],
                    ["serve", "--profile", "a/b"], ["serve", "--profile", ""], ["serve", "extra"], ["serve", "--socket", ""]] as [[String]] {
            XCTAssertThrowsError(try CLI.parse(bad, home: home), "\(bad)")
        }
    }
}
