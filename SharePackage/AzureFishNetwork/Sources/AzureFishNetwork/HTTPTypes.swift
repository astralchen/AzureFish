import Foundation

/// 前台二进制请求的方法；本包不隐式将写请求视为可重试。
public enum HTTPMethod: String, Sendable { case get = "GET", post = "POST", patch = "PATCH" }

/// 明确声明请求可自动重放的条件；最多额外尝试一次。
public enum HTTPReplayPolicy: Sendable, Equatable {
    case never
    case readOnce
    /// 调用方保证服务端按此业务 ID 去重，且重放字节不变。
    case idempotentWriteOnce(operationID: UUID)
}

/// HTTP 请求的不可变内存快照；body 可能包含凭据，不应持久化或写入日志。
public struct HTTPRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let url: URL
    public let method: HTTPMethod
    public let headers: [String: String]
    public let body: Data?
    public let timeout: TimeInterval
    public let maximumResponseBytes: Int
    public let replayPolicy: HTTPReplayPolicy

    /// 创建请求；超时单位为秒，响应上限按解压后的字节计数。
    public init(url: URL, method: HTTPMethod = .get, headers: [String: String] = [:], body: Data? = nil,
                timeout: TimeInterval = 15, maximumResponseBytes: Int = 64 * 1024, replayPolicy: HTTPReplayPolicy = .never) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
        self.timeout = timeout; self.maximumResponseBytes = maximumResponseBytes; self.replayPolicy = replayPolicy
    }

    public var description: String { "HTTPRequest(\(method.rawValue), content redacted)" }
    public var debugDescription: String { description }

    func urlRequest() throws -> URLRequest {
        guard timeout.isFinite, timeout > 0, timeout <= 60, maximumResponseBytes > 0,
              maximumResponseBytes <= 16 * 1024 * 1024 else { throw NetworkError.invalidRequest }
        if method == .get, body != nil { throw NetworkError.invalidRequest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method.rawValue
        request.httpBody = body
        for (name, value) in headers {
            guard !name.isEmpty, name.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains($0)
            }), value.unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) }) else { throw NetworkError.invalidRequest }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

/// 传输响应；不自动解释业务错误，body 只在内存中交给调用方。
public struct HTTPResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode; self.headers = headers; self.body = body
    }
    public func header(_ name: String) -> String? {
        headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }
    public var description: String { "HTTPResponse(status: \(statusCode), content redacted)" }
    public var debugDescription: String { description }
}

/// 不携带 URL、请求头、正文或底层 userInfo 的传输错误。
public enum NetworkError: Error, Sendable, Equatable {
    case invalidRequest
    case insecureURL
    case nonHTTPResponse
    case responseTooLarge(limit: Int)
    case transport(code: URLError.Code)
    case transportFailed
}

/// 决定允许的网络地址；HTTP 例外只在 Debug 的 macOS／iOS 模拟器生效。
public enum TransportSecurityPolicy: Sendable, Equatable {
    case httpsOnly
    case debugLoopbackForFictionalData

    public func validate(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.fragment == nil,
              let host = components.host, !host.isEmpty,
              components.port.map({ (1...65535).contains($0) }) ?? true else { throw NetworkError.invalidRequest }
        if components.scheme?.lowercased() == "https" { return }
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        if self == .debugLoopbackForFictionalData, components.scheme?.lowercased() == "http",
           host == "127.0.0.1" || host == "[::1]" || host == "::1" { return }
        #endif
        throw NetworkError.insecureURL
    }
}

/// 可注入的传输边界；实现必须响应取消、遵守响应上限且不得自行重试。
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
