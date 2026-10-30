import Foundation

/// 导出失败的原因。`code` 是返回给客户端的短错误码，不含任何 cookie 数据；
/// `detail` 只进日志（OSStatus、SQLite 返回码这类诊断信息）。
public enum ExportError: Error, Equatable {
    case noProfile
    /// Chrome 根目录存在但打不开：几乎总是 Full Disk Access 没给或被收回（TCC 返回 EPERM）。
    case chromeRootUnreadable(String)
    case cookiesDBUnreadable(String)
    case keychainDenied(String)
    case internalError(String)

    public var code: String {
        switch self {
        case .noProfile: "no_profile"
        case .chromeRootUnreadable: "chrome_root_unreadable"
        case .cookiesDBUnreadable: "cookies_db_unreadable"
        case .keychainDenied: "keychain_denied"
        case .internalError: "internal_error"
        }
    }

    public var detail: String {
        switch self {
        case .noProfile: ""
        case .chromeRootUnreadable(let d), .cookiesDBUnreadable(let d), .keychainDenied(let d), .internalError(let d): d
        }
    }
}

public struct ExportResult: Equatable, Sendable {
    public var body: String
    public var exported: Int
    public var skipped: Int
    public var profile: String

    public init(body: String, exported: Int, skipped: Int, profile: String) {
        self.body = body
        self.exported = exported
        self.skipped = skipped
        self.profile = profile
    }
}

/// 一次导出：按域名后缀白名单返回 Netscape cookies.txt。
public protocol CookieSource: Sendable {
    func export(suffixes: [String]) throws -> ExportResult
}

/// “Chrome Safe Storage” 的密码来源。真实实现读登录钥匙串，测试里注入固定值。
public protocol ChromePasswordProvider: Sendable {
    func password() throws -> Data
}
