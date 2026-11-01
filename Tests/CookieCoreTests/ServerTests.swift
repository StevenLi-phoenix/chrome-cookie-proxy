import Darwin
import XCTest
@testable import CookieCore

/// 收集日志行（线程安全）。
final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    var logger: RequestLogger { RequestLogger { [self] line in lock.lock(); storage.append(line); lock.unlock() } }
}

private struct CannedSource: CookieSource {
    var body = "# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tFAKE\tfake-value\n"
    func export(suffixes: [String]) throws -> ExportResult {
        ExportResult(body: body, exported: 1, skipped: 0, profile: "Profile 1")
    }
}

/// 在后台线程里跑 server.run()。
final class RunningServer: @unchecked Sendable {
    let server: UnixSocketServer
    private let done = DispatchSemaphore(value: 0)
    private let finished = NSLock()
    private var waited = false

    init(_ server: UnixSocketServer) throws {
        self.server = server
        try server.start()
        Thread { [server, done] in
            server.run()
            done.signal()
        }.start()
    }

    /// 可重复调用：只有第一次真的等线程退出。
    func stopAndWait() {
        server.stop()
        finished.lock(); defer { finished.unlock() }
        guard !waited else { return }
        waited = true
        _ = done.wait(timeout: .now() + 5)
    }
}

/// Darwin socket 客户端：发 bytes，读到 EOF，返回原始响应。
func exchange(_ path: String, send bytes: [UInt8], timeout: Int = 3) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let bytes = Array(path.utf8)
        for (i, b) in bytes.enumerated() { raw[i] = b }
    }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { return nil }
    var sent = 0
    while sent < bytes.count {
        let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break }  // 服务端可能已经回复并关闭
        sent += n
    }
    var out = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return String(decoding: out, as: UTF8.self)
}

func get(_ path: String, _ target: String, method: String = "GET") -> String? {
    exchange(path, send: Array("\(method) \(target) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
}

func statusLine(_ response: String?) -> String? {
    response?.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
}

func body(_ response: String?) -> String? {
    response.flatMap { r in r.range(of: "\r\n\r\n").map { String(r[$0.upperBound...]) } }
}

final class ServerTests: XCTestCase {
    func socketPath() throws -> String {
        try makeTempDir().appendingPathComponent("run/proxy.sock").path
    }

    func start(_ path: String, source: CookieSource = CannedSource(), logs: LogCollector = LogCollector(),
               allowedUIDs: Set<uid_t> = [getuid()], socketMode: mode_t = 0o600,
               readTimeout: TimeInterval = 5) throws -> RunningServer {
        let server = UnixSocketServer(socketPath: path, router: Router(source: source), logger: logs.logger,
                                      allowedUIDs: allowedUIDs, socketMode: socketMode, readTimeout: readTimeout)
        let running = try RunningServer(server)
        addTeardownBlock { running.stopAndWait() }
        return running
    }

    func mode(_ path: String) -> mode_t {
        var st = stat()
        XCTAssertEqual(stat(path, &st), 0, path)
        return st.st_mode & 0o7777
    }

    func testHealthz() throws {
        let path = try socketPath()
        _ = try start(path)
        let r = get(path, "/healthz")
        XCTAssertEqual(statusLine(r), "HTTP/1.1 200 OK")
        XCTAssertEqual(body(r), "ok\n")
        XCTAssertTrue(r?.contains("Connection: close") == true)
        XCTAssertTrue(r?.contains("Content-Type: text/plain; charset=utf-8") == true)
        XCTAssertTrue(r?.contains("Content-Length: 3\r\n") == true)
    }

    func testCookiesRoutes() throws {
        let path = try socketPath()
        _ = try start(path)
        let ok = get(path, "/v1/cookies/youtube")
        XCTAssertEqual(statusLine(ok), "HTTP/1.1 200 OK")
        XCTAssertEqual(body(ok), CannedSource().body)
        XCTAssertEqual(statusLine(get(path, "/v1/cookies/github")), "HTTP/1.1 404 Not Found")
        XCTAssertEqual(statusLine(get(path, "/nope")), "HTTP/1.1 404 Not Found")
        let post = get(path, "/v1/cookies/youtube", method: "POST")
        XCTAssertEqual(statusLine(post), "HTTP/1.1 405 Method Not Allowed")
        XCTAssertFalse(post?.contains("fake-value") == true)
    }

    func testSocketAndDirectoryModes() throws {
        let path = try socketPath()
        _ = try start(path)
        XCTAssertEqual(mode(path), 0o600)
        XCTAssertEqual(mode((path as NSString).deletingLastPathComponent), 0o700)
        var st = stat()
        stat(path, &st)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFSOCK)
    }

    func testExistingLooseDirectoryIsTightened() throws {
        let dir = try makeTempDir().appendingPathComponent("run")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        _ = try start(dir.appendingPathComponent("proxy.sock").path)
        XCTAssertEqual(mode(dir.path), 0o700)
    }

    func testGarbageAndOversizedRequests() throws {
        let path = try socketPath()
        _ = try start(path)
        let garbage = exchange(path, send: Array("\u{1}\u{2}garbage\r\n".utf8))
        XCTAssertEqual(statusLine(garbage), "HTTP/1.1 400 Bad Request")
        XCTAssertEqual(body(garbage), "bad_request\n")
        let big = exchange(path, send: [UInt8](repeating: 0x41, count: 20_000))
        XCTAssertEqual(statusLine(big), "HTTP/1.1 400 Bad Request")
        XCTAssertEqual(body(big), "request_too_large\n")
        // 服务还活着
        XCTAssertEqual(statusLine(get(path, "/healthz")), "HTTP/1.1 200 OK")
    }

    func testSlowClientTimesOutAndServerRecovers() throws {
        let path = try socketPath()
        _ = try start(path, readTimeout: 0.3)
        let r = exchange(path, send: Array("GET /heal".utf8))
        XCTAssertEqual(statusLine(r), "HTTP/1.1 408 Request Timeout")
        XCTAssertEqual(statusLine(get(path, "/healthz")), "HTTP/1.1 200 OK")
    }

    func testForeignUIDIsClosedWithoutResponse() throws {
        let path = try socketPath()
        let logs = LogCollector()
        _ = try start(path, logs: logs, allowedUIDs: [getuid() &+ 1])
        let r = get(path, "/v1/cookies/youtube")
        XCTAssertEqual(r, "")
        XCTAssertTrue(logs.lines.contains { $0.contains("peer uid") && $0.contains("rejected") }, "\(logs.lines)")
    }

    func testSingleUIDRejectionKeepsTheOriginalLogLine() throws {
        let path = try socketPath()
        let logs = LogCollector()
        let other = getuid() &+ 1
        _ = try start(path, logs: logs, allowedUIDs: [other])
        _ = get(path, "/healthz")
        XCTAssertTrue(logs.lines.contains { $0.hasSuffix("rejected connection: peer uid \(getuid()) != \(other)") }, "\(logs.lines)")
    }

    func testPeerInAllowedSetIsServed() throws {
        let path = try socketPath()
        let logs = LogCollector()
        // 白名单里有别的 uid，也有自己：自己照常通过
        _ = try start(path, logs: logs, allowedUIDs: [getuid(), getuid() &+ 7, getuid() &+ 9])
        XCTAssertEqual(statusLine(get(path, "/healthz")), "HTTP/1.1 200 OK")
        XCTAssertFalse(logs.lines.contains { $0.contains("rejected") }, "\(logs.lines)")
    }

    func testPeerOutsideAllowedSetIsRejectedAndLogged() throws {
        let path = try socketPath()
        let logs = LogCollector()
        _ = try start(path, logs: logs, allowedUIDs: [getuid() &+ 7, getuid() &+ 9])
        XCTAssertEqual(get(path, "/healthz"), "")
        let line = try XCTUnwrap(logs.lines.first { $0.contains("rejected connection") }, "\(logs.lines)")
        XCTAssertTrue(line.contains("peer uid \(getuid())"), line)
        XCTAssertTrue(line.contains("\(getuid() &+ 7)") && line.contains("\(getuid() &+ 9)"), line)  // 写出白名单，便于排错
        // 服务没被一个被拒绝的连接拖垮
        XCTAssertEqual(get(path, "/healthz"), "")
    }

    func testSocketModeIsApplied() throws {
        let path = try socketPath()
        _ = try start(path, socketMode: 0o666)
        XCTAssertEqual(mode(path), 0o666)
        XCTAssertEqual(mode((path as NSString).deletingLastPathComponent), 0o700)  // 目录仍是 0700，由它加 ACL 把关
        XCTAssertEqual(statusLine(get(path, "/healthz")), "HTTP/1.1 200 OK")
    }

    func testDefaultSocketModeStays0600() throws {
        let path = try socketPath()
        let server = UnixSocketServer(socketPath: path, router: Router(source: CannedSource()), logger: LogCollector().logger)
        try server.start()
        defer { unlink(path) }
        XCTAssertEqual(mode(path), 0o600)
    }

    func testRefusesSocketModeWithoutOwnerReadWrite() throws {
        let path = try socketPath()
        let server = UnixSocketServer(socketPath: path, router: Router(source: CannedSource()), logger: LogCollector().logger,
                                      socketMode: 0o444)
        XCTAssertThrowsError(try server.start())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testStopRemovesSocketFile() throws {
        let path = try socketPath()
        let running = try start(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        running.stopAndWait()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testStaleSocketIsReplaced() throws {
        let path = try socketPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // 模拟上次崩溃：socket 文件留在原地，没有进程在监听
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in path.utf8.enumerated() { raw[i] = b } }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        XCTAssertEqual(rc, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertNil(get(path, "/healthz"))  // 连不上

        _ = try start(path)
        XCTAssertEqual(statusLine(get(path, "/healthz")), "HTTP/1.1 200 OK")
    }

    func testRefusesNonSocketAtPath() throws {
        let path = try socketPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try "precious".write(toFile: path, atomically: true, encoding: .utf8)
        let server = UnixSocketServer(socketPath: path, router: Router(source: CannedSource()), logger: LogCollector().logger)
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "precious")
    }

    func testRefusesDirectoryNotOwnedByCurrentUser() throws {
        // /private/tmp 属于 root：必须拒绝启动，且不能改它的权限
        var before = stat()
        XCTAssertEqual(stat("/private/tmp", &before), 0)
        let server = UnixSocketServer(socketPath: "/private/tmp/ccp-should-not-exist.sock",
                                      router: Router(source: CannedSource()), logger: LogCollector().logger)
        XCTAssertThrowsError(try server.start())
        var after = stat()
        XCTAssertEqual(stat("/private/tmp", &after), 0)
        XCTAssertEqual(before.st_mode, after.st_mode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/private/tmp/ccp-should-not-exist.sock"))
    }

    func testRefusesOverlongSocketPath() throws {
        let long = try makeTempDir().appendingPathComponent(String(repeating: "x", count: 120) + "/p.sock").path
        let server = UnixSocketServer(socketPath: long, router: Router(source: CannedSource()), logger: LogCollector().logger)
        XCTAssertThrowsError(try server.start())
    }

    func testFullStackOverRealExporterAndLogsNeverContainCookieData() throws {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("chrome")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FixtureChrome(root: root).addProfile("Default", metaVersion: 23, rows: Vectors.defaultRows,
                                                 modified: Date(timeIntervalSince1970: 1_700_000_000))
        try FixtureChrome(root: root).addProfile("Profile 1", metaVersion: 24, rows: Vectors.profile1Rows,
                                                 modified: Date(timeIntervalSince1970: 1_800_000_000))
        let logs = LogCollector()
        let source = ChromeCookieSource(chromeRoot: root, profile: nil, passwords: FixedPassword())
        let path = try socketPath()
        _ = try start(path, source: source, logs: logs)

        let r = get(path, "/v1/cookies/youtube")
        XCTAssertEqual(statusLine(r), "HTTP/1.1 200 OK")
        let b = try XCTUnwrap(body(r))
        XCTAssertTrue(b.hasPrefix("# Netscape HTTP Cookie File\n"))
        XCTAssertTrue(b.contains("\tLOGIN_INFO\tlogin-info-secret-1\n"))
        XCTAssertTrue(b.contains("\t__Secure-3PSID\tpsid-secret-2\n"))
        XCTAssertFalse(b.contains("claude"))
        XCTAssertFalse(b.contains("github"))

        // 失败路径也要走一遍
        _ = get(path, "/v1/cookies/github")
        _ = get(path, "/healthz")

        let log = logs.lines.joined(separator: "\n")
        XCTAssertTrue(log.contains("/v1/cookies/youtube"))
        XCTAssertTrue(log.contains("200"))
        XCTAssertTrue(log.contains("exported=3"))
        XCTAssertTrue(log.contains("skipped=3"))
        XCTAssertTrue(log.contains("Profile 1"))
        for secret in ["LOGIN_INFO", "login-info-secret-1", "__Secure-3PSID", "psid-secret-2", "plain-value-5", "PLAIN_ONE",
                       "sessionKey", "claude-session-3", "user_session", "github-session-4", "peanuts", "BAD_HASH"] {
            XCTAssertFalse(log.contains(secret), secret)
        }
    }

    func testKeychainFailureIs500WithShortCodeAndNoDataInBodyOrLog() throws {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("chrome")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FixtureChrome(root: root).addProfile("Default", metaVersion: 24, rows: Vectors.profile1Rows, modified: Date())
        let logs = LogCollector()
        let path = try socketPath()
        _ = try start(path, source: ChromeCookieSource(chromeRoot: root, profile: nil, passwords: DeniedPassword()), logs: logs)
        let r = get(path, "/v1/cookies/youtube")
        XCTAssertEqual(statusLine(r), "HTTP/1.1 500 Internal Server Error")
        XCTAssertEqual(body(r), "keychain_denied\n")
        XCTAssertTrue(logs.lines.joined().contains("keychain_denied"))
        XCTAssertFalse(logs.lines.joined().contains("login-info-secret-1"))
    }

    func testSequentialConnections() throws {
        let path = try socketPath()
        _ = try start(path)
        for _ in 0..<20 {
            XCTAssertEqual(statusLine(get(path, "/healthz")), "HTTP/1.1 200 OK")
        }
    }
}
