import Foundation

public struct ServeOptions: Equatable, Sendable {
    public var socketPath: String
    public var chromeRoot: String
    public var profile: String?

    public init(socketPath: String, chromeRoot: String, profile: String?) {
        self.socketPath = socketPath
        self.chromeRoot = chromeRoot
        self.profile = profile
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
               chrome-cookie-proxy version

          --socket       unix socket path (default ~/.local/state/chrome-cookie-proxy/proxy.sock)
          --chrome-root  Chrome user data dir (default ~/Library/Application Support/Google/Chrome)
          --profile      profile directory name (default: newest of Default and Profile *)
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
                guard ["--socket", "--chrome-root", "--profile"].contains(flag) else {
                    throw CLIError(description: "unknown argument: \(flag)")
                }
                guard let value = rest.popFirst(), !value.isEmpty else {
                    throw CLIError(description: "\(flag) needs a value")
                }
                switch flag {
                case "--socket": options.socketPath = value
                case "--chrome-root": options.chromeRoot = value
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
