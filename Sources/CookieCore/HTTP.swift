import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var version: String

    public init(method: String, path: String, version: String) {
        self.method = method
        self.path = path
        self.version = version
    }
}

public enum HTTPParseError: Error, Equatable {
    /// 还没读到完整的请求行
    case incomplete
    case malformed
    case tooLarge
}

/// 极简 HTTP/1.x：只看请求行 `METHOD /path HTTP/1.x`，头部读完即丢。
public enum HTTPRequestParser {
    public static let maxRequestBytes = 8192

    public static func parse(_ data: [UInt8]) -> Result<HTTPRequest, HTTPParseError> {
        if data.count > maxRequestBytes { return .failure(.tooLarge) }
        guard let newline = data.firstIndex(of: 0x0A) else {
            return .failure(data.count >= maxRequestBytes ? .tooLarge : .incomplete)
        }
        var line = data[..<newline]
        if line.last == 0x0D { line = line.dropLast() }

        let parts = line.split(separator: 0x20, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return .failure(.malformed) }
        let (method, path, version) = (parts[0], parts[1], parts[2])
        guard !method.isEmpty, method.allSatisfy({ (0x41...0x5A).contains($0) }),
              path.first == 0x2F, path.allSatisfy({ (0x21...0x7E).contains($0) }),
              let versionText = String(bytes: version, encoding: .ascii), versionText == "HTTP/1.0" || versionText == "HTTP/1.1"
        else { return .failure(.malformed) }
        return .success(HTTPRequest(method: String(decoding: method, as: UTF8.self),
                                    path: String(decoding: path, as: UTF8.self), version: versionText))
    }

    /// 头部是否已经结束（空行：`\r\n\r\n` 或 `\n\n`）。
    public static func headersEnded(_ data: [UInt8]) -> Bool {
        for i in data.indices where data[i] == 0x0A {
            let next = i + 1
            guard next < data.count else { return false }
            if data[next] == 0x0A { return true }
            if data[next] == 0x0D, next + 1 < data.count, data[next + 1] == 0x0A { return true }
        }
        return false
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: String
    public var headers: [(String, String)]

    public init(status: Int, body: String, headers: [(String, String)] = []) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 500: "Internal Server Error"
        default: "Unknown"
        }
    }

    public func serialized() -> [UInt8] {
        let payload = Array(body.utf8)
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        return Array(head.utf8) + payload
    }
}

/// 一次请求的结果加上日志需要的字段。这里面不会有 cookie 的名字或值。
public struct RequestOutcome: Sendable {
    public var response: HTTPResponse
    public var method: String?
    public var path: String?
    public var exported = 0
    public var skipped = 0
    public var profile: String?
    /// 短错误码（与 500 响应体一致）
    public var error: String?
    /// 只进日志的诊断信息（OSStatus、SQLite 返回码）
    public var errorDetail: String?
}

public struct Router: Sendable {
    let source: CookieSource

    public init(source: CookieSource) { self.source = source }

    public func handle(_ parsed: Result<HTTPRequest, HTTPParseError>) -> RequestOutcome {
        switch parsed {
        case .failure(.malformed): return RequestOutcome(response: HTTPResponse(status: 400, body: "bad_request\n"))
        case .failure(.tooLarge): return RequestOutcome(response: HTTPResponse(status: 400, body: "request_too_large\n"))
        case .failure(.incomplete): return RequestOutcome(response: HTTPResponse(status: 408, body: "request_timeout\n"))
        case .success(let request): return handle(request)
        }
    }

    private func handle(_ request: HTTPRequest) -> RequestOutcome {
        var outcome = RequestOutcome(response: HTTPResponse(status: 404, body: "not_found\n"),
                                     method: request.method, path: request.path)
        guard request.method == "GET" else {
            outcome.response = HTTPResponse(status: 405, body: "method_not_allowed\n", headers: [("Allow", "GET")])
            return outcome
        }
        if request.path == "/healthz" {
            outcome.response = HTTPResponse(status: 200, body: "ok\n")
            return outcome
        }
        let prefix = "/v1/cookies/"
        guard request.path.hasPrefix(prefix), let suffixes = CookieSets.table[String(request.path.dropFirst(prefix.count))] else {
            return outcome
        }
        do {
            let result = try source.export(suffixes: suffixes)
            outcome.response = HTTPResponse(status: 200, body: result.body)
            outcome.exported = result.exported
            outcome.skipped = result.skipped
            outcome.profile = result.profile
        } catch {
            let failure = (error as? ExportError) ?? .internalError("\(type(of: error))")
            outcome.response = HTTPResponse(status: 500, body: failure.code + "\n")
            outcome.error = failure.code
            outcome.errorDetail = failure.detail.isEmpty ? nil : failure.detail
        }
        return outcome
    }
}
