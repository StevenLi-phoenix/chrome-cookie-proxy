import Foundation

public struct ServeOptions: Equatable, Sendable {
    public var socketPath: String
    public var chromeRoot: String
    public var profile: String?
    /// 除服务自己的 uid 以外，还允许连接的 uid（`--allow-uid`，可重复）。空 = 只允许自己（原行为）。
    public var allowUIDs: [UInt32]
    /// socket 文件的权限位（`--socket-mode`）。nil = 0600（原行为）。
    public var socketMode: UInt16?

    public init(socketPath: String, chromeRoot: String, profile: String?,
                allowUIDs: [UInt32] = [], socketMode: UInt16? = nil) {
        self.socketPath = socketPath
        self.chromeRoot = chromeRoot
        self.profile = profile
        self.allowUIDs = allowUIDs
        self.socketMode = socketMode
    }
}

public enum Command: Equatable, Sendable {
    case serve(ServeOptions)
    case version
    case help
}

public struct CLIError: Error, Equatable, CustomStringConvertible {
    public var description: String
}

public enum CLI {
    public static let usage = """
        usage: chrome-cookie-proxy serve [--socket <path>] [--chrome-root <dir>] [--profile <name>]
                                        [--allow-uid <uid>]... [--socket-mode <octal>]
               chrome-cookie-proxy version

          --socket       unix socket path (default ~/.local/state/chrome-cookie-proxy/proxy.sock)
          --chrome-root  Chrome user data dir (default ~/Library/Application Support/Google/Chrome)
          --profile      profile directory name (default: newest of Default and Profile *)
          --allow-uid    also accept connections from this uid (repeatable; the service's own uid is always accepted)
          --socket-mode  socket file mode in octal, owner must keep rw (default 0600; 0666 lets other uids connect
                         when the directory's ACL allows them in)
        """

    public static func parse(_ args: [String], home: String) throws -> Command {
        guard let first = args.first else { throw CLIError(description: "missing command") }
        switch first {
        case "help", "--help", "-h":
            return .help
        case "version", "--version":
            guard args.count == 1 else { throw CLIError(description: "unknown argument: \(args[1])") }
            return .version
        case "serve":
            var options = ServeOptions(
                socketPath: home + "/.local/state/chrome-cookie-proxy/proxy.sock",
                chromeRoot: home + "/Library/Application Support/Google/Chrome",
                profile: nil)
            var rest = args.dropFirst()[...]
            while let flag = rest.popFirst() {
                guard ["--socket", "--chrome-root", "--profile", "--allow-uid", "--socket-mode"].contains(flag) else {
                    throw CLIError(description: "unknown argument: \(flag)")
                }
                guard let value = rest.popFirst(), !value.isEmpty else {
                    throw CLIError(description: "\(flag) needs a value")
                }
                switch flag {
                case "--socket": options.socketPath = value
                case "--chrome-root": options.chromeRoot = value
                case "--allow-uid":
                    guard value.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let uid = UInt32(value) else {
                        throw CLIError(description: "--allow-uid needs a non-negative integer uid, got \"\(value)\"")
                    }
                    if !options.allowUIDs.contains(uid) { options.allowUIDs.append(uid) }
                case "--socket-mode":
                    guard value.utf8.count <= 4, value.utf8.allSatisfy({ (0x30...0x37).contains($0) }),
                          let mode = UInt16(value, radix: 8), mode <= 0o777, mode & 0o600 == 0o600 else {
                        throw CLIError(description: "--socket-mode needs an octal mode up to 0777 that keeps owner read/write, got \"\(value)\"")
                    }
                    options.socketMode = mode
                default:
                    guard !value.contains("/"), value != ".", value != ".." else {
                        throw CLIError(description: "--profile must be a directory name, not a path")
                    }
                    options.profile = value
                }
            }
            return .serve(options)
        default:
            throw CLIError(description: "unknown command: \(first)")
        }
    }
}
