import Darwin
import Dispatch
import Foundation

public enum Service {
    public static let version = "0.2.0"

    /// `serve` 子命令：启动、处理 SIGTERM/SIGINT、阻塞到退出。
    public static func serve(_ options: ServeOptions, logger: RequestLogger = .stderr) throws {
        let source = ChromeCookieSource(
            chromeRoot: URL(fileURLWithPath: options.chromeRoot, isDirectory: true),
            profile: options.profile,
            passwords: KeychainPasswordProvider())
        let allowed = Set([getuid()] + options.allowUIDs.map { uid_t($0) })
        let server = UnixSocketServer(socketPath: options.socketPath, router: Router(source: source), logger: logger,
                                      allowedUIDs: allowed, socketMode: mode_t(options.socketMode ?? 0o600))
        try server.start()

        signal(SIGPIPE, SIG_IGN)
        let signalSources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            s.setEventHandler { [logger] in
                logger.info("received signal \(sig), shutting down")
                server.stop()
            }
            s.resume()
            return s
        }

        logger.info("chrome-cookie-proxy \(version) listening on \(options.socketPath) "
            + "chrome_root=\"\(options.chromeRoot)\" profile=\(options.profile.map { "\"\($0)\"" } ?? "auto") uid=\(getuid()) "
            + "allowed_uids=\(allowed.sorted()) socket_mode=\(String(options.socketMode ?? 0o600, radix: 8))")
        server.run()
        signalSources.forEach { $0.cancel() }
    }
}
