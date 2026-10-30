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

    func testHelpAndErrors() {
        XCTAssertEqual(try CLI.parse(["--help"], home: home), .help)
        XCTAssertEqual(try CLI.parse(["help"], home: home), .help)
        for bad in [[], ["bogus"], ["serve", "--nope"], ["serve", "--socket"], ["serve", "--profile", "../x"],
                    ["serve", "--profile", "a/b"], ["serve", "--profile", ""], ["serve", "extra"], ["serve", "--socket", ""]] as [[String]] {
            XCTAssertThrowsError(try CLI.parse(bad, home: home), "\(bad)")
        }
    }
}
