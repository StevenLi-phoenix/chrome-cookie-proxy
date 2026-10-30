import Foundation

/// 一次请求一行日志写到 stderr（launchd 会重定向）。
/// 只记时间、方法、路径、状态码、导出/跳过条数、profile 名；cookie 的名字、值和钥匙串密码永远不进日志。
public struct RequestLogger: Sendable {
    private let sink: @Sendable (String) -> Void

    public init(sink: @escaping @Sendable (String) -> Void) { self.sink = sink }

    public static let stderr = RequestLogger { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    public func info(_ message: String) {
        sink("\(Self.timestamp()) \(message)")
    }

    public func request(_ outcome: RequestOutcome) {
        var line = "\(Self.clean(outcome.method)) \(Self.clean(outcome.path)) \(outcome.response.status)"
        line += " exported=\(outcome.exported) skipped=\(outcome.skipped)"
        line += " profile=" + (outcome.profile.map { "\"\(Self.clean($0))\"" } ?? "-")
        if let error = outcome.error { line += " error=\(error)" }
        if let detail = outcome.errorDetail { line += " detail=\"\(Self.clean(detail))\"" }
        info(line)
    }

    static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// 来自网络的字符串先清洗：只留可打印 ASCII，截断，防止日志注入。
    static func clean(_ text: String?, limit: Int = 120) -> String {
        guard let text, !text.isEmpty else { return "-" }
        let scalars = text.unicodeScalars.prefix(limit).map { (0x20..<0x7F).contains($0.value) && $0 != "\"" ? Character($0) : "?" }
        return String(scalars) + (text.unicodeScalars.count > limit ? "..." : "")
    }
}
