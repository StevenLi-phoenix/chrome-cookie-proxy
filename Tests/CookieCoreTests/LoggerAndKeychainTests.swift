import Security
import XCTest
@testable import CookieCore

final class LoggerAndKeychainTests: XCTestCase {
    func testKeychainQueryTargetsChromeSafeStorageOnly() {
        // 只检查查询参数本身：测试里绝不调用真实钥匙串
        let q = KeychainPasswordProvider.query
        XCTAssertEqual(q[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(q[kSecAttrService as String] as? String, "Chrome Safe Storage")
        XCTAssertEqual(q[kSecAttrAccount as String] as? String, "Chrome")
        XCTAssertEqual(q[kSecReturnData as String] as? Bool, true)
    }

    func testRequestLineFormat() {
        final class Box: @unchecked Sendable { var lines: [String] = [] }
        let box = Box()
        let logger = RequestLogger { box.lines.append($0) }
        var outcome = RequestOutcome(response: HTTPResponse(status: 200, body: "x"), method: "GET", path: "/v1/cookies/youtube")
        outcome.exported = 3
        outcome.skipped = 1
        outcome.profile = "Profile 1"
        logger.request(outcome)
        var failed = RequestOutcome(response: HTTPResponse(status: 500, body: "x"), method: "GET", path: "/v1/cookies/youtube")
        failed.error = "keychain_denied"
        failed.errorDetail = "OSStatus -25293"
        logger.request(failed)
        logger.request(RequestOutcome(response: HTTPResponse(status: 400, body: "x")))

        XCTAssertTrue(box.lines[0].range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ GET /v1/cookies/youtube 200 exported=3 skipped=1 profile="Profile 1"$"#,
                                         options: .regularExpression) != nil, box.lines[0])
        XCTAssertTrue(box.lines[1].hasSuffix(#"500 exported=0 skipped=0 profile=- error=keychain_denied detail="OSStatus -25293""#), box.lines[1])
        XCTAssertTrue(box.lines[2].hasSuffix("- - 400 exported=0 skipped=0 profile=-"), box.lines[2])
    }

    func testUntrustedTextIsCleanedBeforeLogging() {
        XCTAssertEqual(RequestLogger.clean("/a\r\nFAKE LOG LINE"), "/a??FAKE LOG LINE")
        XCTAssertEqual(RequestLogger.clean("é\u{0}\"x"), "???x")
        XCTAssertEqual(RequestLogger.clean(nil), "-")
        XCTAssertEqual(RequestLogger.clean(String(repeating: "a", count: 500)).count, 123)
    }
}
