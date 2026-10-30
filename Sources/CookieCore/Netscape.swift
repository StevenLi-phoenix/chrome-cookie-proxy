import Foundation

public struct ChromeCookie: Equatable, Sendable {
    public var hostKey: String
    public var name: String
    public var value: String
    public var path: String
    /// Chrome 的 expires_utc：自 1601-01-01 起的微秒数，0 表示 session cookie。
    public var expiresUTC: Int64
    public var isSecure: Bool

    public init(hostKey: String, name: String, value: String, path: String, expiresUTC: Int64, isSecure: Bool) {
        self.hostKey = hostKey
        self.name = name
        self.value = value
        self.path = path
        self.expiresUTC = expiresUTC
        self.isSecure = isSecure
    }
}

public enum Netscape {
    public static let header = "# Netscape HTTP Cookie File"
    static let chromeEpochOffsetSeconds: Int64 = 11_644_473_600

    public static func unixExpiry(chromeMicros: Int64) -> Int64 {
        chromeMicros == 0 ? 0 : chromeMicros / 1_000_000 - chromeEpochOffsetSeconds
    }

    /// 任何字段含 tab 或换行都会破坏行格式，这样的 cookie 整条跳过。
    public static func isSafe(_ field: String) -> Bool {
        !field.utf8.contains { $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    public static func line(for c: ChromeCookie) -> String {
        [
            c.hostKey,
            c.hostKey.hasPrefix(".") ? "TRUE" : "FALSE",
            c.path,
            c.isSecure ? "TRUE" : "FALSE",
            String(unixExpiry(chromeMicros: c.expiresUTC)),
            c.name,
            c.value,
        ].joined(separator: "\t")
    }

    /// 按 domain、name（再按 path）排序，输出稳定。
    public static func render(_ cookies: [ChromeCookie]) -> String {
        let sorted = cookies.sorted {
            ($0.hostKey, $0.name, $0.path) < ($1.hostKey, $1.name, $1.path)
        }
        return ([header] + sorted.map(line(for:))).joined(separator: "\n") + "\n"
    }
}
