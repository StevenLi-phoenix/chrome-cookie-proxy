import Darwin
import Dispatch
import Foundation

public enum Service {
    public static let version = "0.1.2"

    /// `serve` 子命令：启动、处理 SIGTERM/SIGINT、阻塞到退出。
    public static func serve(_ options: ServeOptions, logger: RequestLogger = .stderr) throws {
        let source = ChromeCookieSource(
            chromeRoot: URL(fileURLWithPath: options.chromeRoot, isDirectory: true),
            profile: options.profile,
            passwords: KeychainPasswordProvider())
        let server = UnixSocketServer(socketPath: options.socketPath, router: Router(source: source), logger: logger)
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
            + "chrome_root=\"\(options.chromeRoot)\" profile=\(options.profile.map { "\"\($0)\"" } ?? "auto") uid=\(getuid())")
        server.run()
        signalSources.forEach { $0.cancel() }
    }
}
