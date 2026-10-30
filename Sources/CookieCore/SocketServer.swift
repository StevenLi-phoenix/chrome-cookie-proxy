import Darwin
import Foundation

public struct ServerError: Error, CustomStringConvertible {
    public var description: String
}

/// 监听一个 unix socket，串行处理连接（一次一个）。
/// 每个连接先核对对方 uid，再读最多 8 KB（5 秒超时）的请求，交给 Router，写回响应后关闭。
public final class UnixSocketServer: @unchecked Sendable {
    private static let maxPathBytes = 103  // sockaddr_un.sun_path 是 104 字节，要留一个 NUL

    private let socketPath: String
    private let router: Router
    private let logger: RequestLogger
    private let allowedUID: uid_t
    private let readTimeout: TimeInterval

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1

    public init(socketPath: String, router: Router, logger: RequestLogger,
                allowedUID: uid_t = getuid(), readTimeout: TimeInterval = 5) {
        self.socketPath = URL(fileURLWithPath: socketPath).path
        self.router = router
        self.logger = logger
        self.allowedUID = allowedUID
        self.readTimeout = readTimeout
    }

    // MARK: - 启动

    /// 准备目录（0700、属于当前用户）、清掉残留 socket、bind、chmod 0600、listen。
    public func start() throws {
        guard socketPath.utf8.count <= Self.maxPathBytes else {
            throw ServerError(description: "socket path is longer than \(Self.maxPathBytes) bytes: \(socketPath)")
        }
        try prepareDirectory((socketPath as NSString).deletingLastPathComponent)
        try removeStaleSocket()

        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw ServerError(description: "pipe: errno \(errno)") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            close(pipeFDs[0]); close(pipeFDs[1])
            throw ServerError(description: "socket: errno \(errno)")
        }
        func fail(_ what: String) -> ServerError {
            let code = errno
            close(fd); close(pipeFDs[0]); close(pipeFDs[1])
            unlink(socketPath)
            return ServerError(description: "\(what): errno \(code)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, byte) in socketPath.utf8.enumerated() { raw[i] = byte }
        }
        // 先用 umask 让 socket 一创建就是 0600，再显式 chmod 一次。
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard bound == 0 else { throw fail("bind \(socketPath)") }
        guard chmod(socketPath, 0o600) == 0 else { throw fail("chmod socket") }
        guard listen(fd, 16) == 0 else { throw fail("listen") }

        lock.lock()
        listenFD = fd
        wakeRead = pipeFDs[0]
        wakeWrite = pipeFDs[1]
        lock.unlock()
    }

    private func prepareDirectory(_ dir: String) throws {
        var st = stat()
        if lstat(dir, &st) != 0 {
            guard errno == ENOENT else { throw ServerError(description: "stat \(dir): errno \(errno)") }
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw ServerError(description: "create \(dir): \(error.localizedDescription)")
            }
            guard lstat(dir, &st) == 0 else { throw ServerError(description: "stat \(dir): errno \(errno)") }
        }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw ServerError(description: "\(dir) is not a directory") }
        guard st.st_uid == getuid() else {
            throw ServerError(description: "\(dir) is owned by uid \(st.st_uid), not the current user (\(getuid()))")
        }
        if st.st_mode & 0o7777 != 0o700, chmod(dir, 0o700) != 0 {
            throw ServerError(description: "chmod \(dir): errno \(errno)")
        }
    }

    private func removeStaleSocket() throws {
        var st = stat()
        guard lstat(socketPath, &st) == 0 else {
            if errno == ENOENT { return }
            throw ServerError(description: "stat \(socketPath): errno \(errno)")
        }
        guard st.st_mode & S_IFMT == S_IFSOCK else {
            throw ServerError(description: "\(socketPath) exists and is not a socket")
        }
        guard unlink(socketPath) == 0 else { throw ServerError(description: "unlink \(socketPath): errno \(errno)") }
    }

    // MARK: - 运行与停止

    /// 阻塞直到 `stop()`；退出前关掉监听并删掉 socket 文件。
    public func run() {
        lock.lock()
        let (fd, wake) = (listenFD, wakeRead)
        lock.unlock()
        guard fd >= 0 else { return }

        loop: while true {
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
            if poll(&fds, 2, -1) < 0 {
                if errno == EINTR { continue }
                logger.info("poll failed: errno \(errno)")
                break
            }
            if fds[1].revents != 0 { break }
            guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno != EINTR, errno != ECONNABORTED { logger.info("accept failed: errno \(errno)") }
                continue
            }
            handle(client)
        }

        lock.lock()
        close(listenFD); close(wakeRead); close(wakeWrite)
        listenFD = -1; wakeRead = -1; wakeWrite = -1
        lock.unlock()
        unlink(socketPath)
        logger.info("stopped, removed \(socketPath)")
    }

    /// 可以从任何线程（信号处理的 DispatchSource）调用，重复调用无害。
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard wakeWrite >= 0 else { return }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
    }

    // MARK: - 单个连接

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: Int(readTimeout.rounded(.up)), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == allowedUID else {
            logger.info("rejected connection: peer uid \(uid) != \(allowedUID)")
            return
        }

        guard let parsed = readRequest(fd) else {
            logger.info("closed connection without a request")
            return
        }
        let outcome = router.handle(parsed)
        writeAll(fd, outcome.response.serialized())
        logger.request(outcome)
        drain(fd)
    }

    /// 读到头部结束、请求行出错、满 8 KB 或超时为止。对端没发任何东西就关了，返回 nil。
    private func readRequest(_ fd: Int32) -> Result<HTTPRequest, HTTPParseError>? {
        let deadline = Date().addingTimeInterval(readTimeout)
        let limit = HTTPRequestParser.maxRequestBytes
        var data: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 2048)

        while true {
            let parsed = HTTPRequestParser.parse(data)
            switch parsed {
            case .failure(.malformed), .failure(.tooLarge): return parsed
            case .success where HTTPRequestParser.headersEnded(data): return parsed
            default: break
            }
            if data.count >= limit { return .failure(.tooLarge) }

            let remainingMs = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, remainingMs)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { return .failure(.incomplete) }

            let n = read(fd, &chunk, min(chunk.count, limit - data.count))
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 {  // 对端关了写端：有完整请求行就照常处理
                if data.isEmpty { return nil }
                if case .success = parsed { return parsed }
                return .failure(.malformed)
            }
            data.append(contentsOf: chunk[0..<n])
        }
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            sent += n
        }
    }

    /// 先半关闭写端，再把对端还没发完的数据读掉（最多 64 KB / 200 ms），
    /// 避免带着未读数据 close 导致 RST 把已经写出的响应冲掉。
    private func drain(_ fd: Int32) {
        shutdown(fd, SHUT_WR)
        let deadline = Date().addingTimeInterval(0.2)
        var budget = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: 4096)
        while budget > 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remainingMs = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard poll(&pfd, 1, remainingMs) > 0 else { return }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            budget -= n
        }
    }
}
