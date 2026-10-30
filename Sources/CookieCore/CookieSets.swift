import Foundation

/// 编译期写死的白名单：set 名 -> 域名后缀。要新增一个 set 只能改代码重新发布。
public enum CookieSets {
    public static let table: [String: [String]] = [
        "youtube": ["youtube.com", "google.com"],
    ]

    /// 去掉 host_key 开头的一个 `.` 后，等于某个后缀或以 `"." + 后缀` 结尾才算命中。
    /// 含空 label 的主机名（`..a.com`、`a.com.`、空串）一律不命中。
    public static func matches(hostKey: String, suffixes: [String]) -> Bool {
        var host = hostKey.lowercased()
        if host.hasPrefix(".") { host.removeFirst() }
        guard !host.isEmpty, !host.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty) else {
            return false
        }
        return suffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
