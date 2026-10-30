import XCTest
@testable import CookieCore

final class HTTPParserTests: XCTestCase {
    func parse(_ s: String) -> Result<HTTPRequest, HTTPParseError> {
        HTTPRequestParser.parse(Array(s.utf8))
    }

    func testValidGet() throws {
        let r = try parse("GET /healthz HTTP/1.1\r\nHost: localhost\r\nUser-Agent: curl\r\n\r\n").get()
        XCTAssertEqual(r, HTTPRequest(method: "GET", path: "/healthz", version: "HTTP/1.1"))
        XCTAssertEqual(try parse("GET /v1/cookies/youtube HTTP/1.0\r\n\r\n").get().version, "HTTP/1.0")
    }

    func testBareLFLineEndings() throws {
        XCTAssertEqual(try parse("GET /healthz HTTP/1.1\n\n").get().path, "/healthz")
    }

    func testUnknownPathAndMethodStillParse() throws {
        // 路由由 Router 决定，解析只管格式
        XCTAssertEqual(try parse("GET /nope HTTP/1.1\r\n\r\n").get().path, "/nope")
        XCTAssertEqual(try parse("POST /healthz HTTP/1.1\r\n\r\n").get().method, "POST")
    }

    func testMalformed() {
        let bad = [
            "garbage\r\n",
            "\u{0}\u{1}\u{2}\u{3}\r\n",
            "GET /healthz\r\n",
            "GET /healthz HTTP/1.1 extra\r\n",
            "GET  /healthz HTTP/1.1\r\n",
            "GET /healthz HTTP/2.0\r\n",
            "GET /healthz HTTP/1.2\r\n",
            "GET healthz HTTP/1.1\r\n",
            "get /healthz HTTP/1.1\r\n",
            "GET /heal\u{0}thz HTTP/1.1\r\n",
            "\r\n",
            " GET /healthz HTTP/1.1\r\n",
        ]
        for s in bad {
            XCTAssertEqual(parse(s), .failure(.malformed), s.debugDescription)
        }
    }

    func testIncompleteWithoutNewline() {
        XCTAssertEqual(parse("GET /heal"), .failure(.incomplete))
        XCTAssertEqual(parse(""), .failure(.incomplete))
    }

    func testOversized() {
        XCTAssertEqual(HTTPRequestParser.maxRequestBytes, 8192)
        XCTAssertEqual(parse(String(repeating: "A", count: 9000)), .failure(.tooLarge))
        XCTAssertEqual(parse("GET /" + String(repeating: "a", count: 9000) + " HTTP/1.1\r\n\r\n"), .failure(.tooLarge))
        // 整整 8192 字节、没有换行：读满了还没有首行
        XCTAssertEqual(parse(String(repeating: "A", count: 8192)), .failure(.tooLarge))
        // 8192 字节以内且合法
        let pad = String(repeating: "x", count: 8000)
        XCTAssertNoThrow(try parse("GET /healthz HTTP/1.1\r\nX-Pad: \(pad)\r\n\r\n").get())
    }

    func testHeaderEnd() {
        XCTAssertTrue(HTTPRequestParser.headersEnded(Array("GET / HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertTrue(HTTPRequestParser.headersEnded(Array("GET / HTTP/1.1\n\n".utf8)))
        XCTAssertFalse(HTTPRequestParser.headersEnded(Array("GET / HTTP/1.1\r\nHost: x\r\n".utf8)))
    }
}

private final class StubSource: CookieSource, @unchecked Sendable {
    var calls: [[String]] = []
    var result: Result<ExportResult, Error>
    init(_ result: Result<ExportResult, Error> = .success(ExportResult(body: "BODY\n", exported: 2, skipped: 1, profile: "Default"))) {
        self.result = result
    }
    func export(suffixes: [String]) throws -> ExportResult {
        calls.append(suffixes)
        return try result.get()
    }
}

final class RouterTests: XCTestCase {
    func req(_ method: String, _ path: String) -> HTTPRequest {
        HTTPRequest(method: method, path: path, version: "HTTP/1.1")
    }

    func testHealthzDoesNotTouchSource() {
        let src = StubSource()
        let out = Router(source: src).handle(.success(req("GET", "/healthz")))
        XCTAssertEqual(out.response.status, 200)
        XCTAssertEqual(out.response.body, "ok\n")
        XCTAssertTrue(src.calls.isEmpty)
    }

    func testYoutubeSetUsesCompiledInSuffixes() {
        let src = StubSource()
        let out = Router(source: src).handle(.success(req("GET", "/v1/cookies/youtube")))
        XCTAssertEqual(out.response.status, 200)
        XCTAssertEqual(out.response.body, "BODY\n")
        XCTAssertEqual(src.calls, [["youtube.com", "google.com"]])
        XCTAssertEqual(out.exported, 2)
        XCTAssertEqual(out.skipped, 1)
        XCTAssertEqual(out.profile, "Default")
    }

    func testUnknownSetAndPathsAre404() {
        let src = StubSource()
        let router = Router(source: src)
        for path in ["/v1/cookies/github", "/v1/cookies/", "/v1/cookies", "/v1/cookies/youtube/", "/nope", "/", "/v1/cookies/youtube?x=1",
                     "/v1/cookies/../healthz"] {
            XCTAssertEqual(router.handle(.success(req("GET", path))).response.status, 404, path)
        }
        XCTAssertTrue(src.calls.isEmpty)
    }

    func testWrongMethodIs405() {
        let src = StubSource()
        let router = Router(source: src)
        for m in ["POST", "PUT", "DELETE", "HEAD", "OPTIONS"] {
            let out = router.handle(.success(req(m, "/v1/cookies/youtube")))
            XCTAssertEqual(out.response.status, 405, m)
            XCTAssertEqual(out.response.body, "method_not_allowed\n")
        }
        XCTAssertTrue(src.calls.isEmpty)
    }

    func testExportErrorsBecome500WithShortCodeOnly() {
        let cases: [(ExportError, String)] = [
            (.keychainDenied("OSStatus -25293"), "keychain_denied"),
            (.cookiesDBUnreadable("sqlite 14 at /secret/path"), "cookies_db_unreadable"),
            (.noProfile, "no_profile"),
            (.internalError("boom"), "internal_error"),
        ]
        for (err, code) in cases {
            let out = Router(source: StubSource(.failure(err))).handle(.success(req("GET", "/v1/cookies/youtube")))
            XCTAssertEqual(out.response.status, 500)
            XCTAssertEqual(out.response.body, code + "\n")
            XCTAssertEqual(out.error, code)
        }
        struct Other: Error {}
        let out = Router(source: StubSource(.failure(Other()))).handle(.success(req("GET", "/v1/cookies/youtube")))
        XCTAssertEqual(out.response.status, 500)
        XCTAssertEqual(out.response.body, "internal_error\n")
    }

    func testParseFailures() {
        let router = Router(source: StubSource())
        XCTAssertEqual(router.handle(.failure(.malformed)).response.status, 400)
        XCTAssertEqual(router.handle(.failure(.tooLarge)).response.status, 400)
        XCTAssertEqual(router.handle(.failure(.tooLarge)).response.body, "request_too_large\n")
        XCTAssertEqual(router.handle(.failure(.incomplete)).response.status, 408)
    }

    func testSerialization() throws {
        let bytes = HTTPResponse(status: 200, body: "ok\n").serialized()
        let s = try XCTUnwrap(String(bytes: bytes, encoding: .utf8))
        XCTAssertTrue(s.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(s.contains("\r\nContent-Type: text/plain; charset=utf-8\r\n"))
        XCTAssertTrue(s.contains("\r\nContent-Length: 3\r\n"))
        XCTAssertTrue(s.contains("\r\nConnection: close\r\n"))
        XCTAssertTrue(s.hasSuffix("\r\n\r\nok\n"))
    }

    func testContentLengthCountsBytesNotCharacters() throws {
        let s = String(decoding: HTTPResponse(status: 200, body: "é\n").serialized(), as: UTF8.self)
        XCTAssertTrue(s.contains("Content-Length: 3\r\n"))
    }
}
