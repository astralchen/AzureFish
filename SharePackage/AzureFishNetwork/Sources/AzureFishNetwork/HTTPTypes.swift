import Foundation

/// HTTP 请求的方法，原始值为发送到服务端的大写方法名。
public enum HTTPMethod: String, Sendable {
    /// 读取资源；`HTTPClient` 不允许 GET 携带非 `nil` 正文，包括空 Data。
    case get = "GET"
    /// 提交业务动作；是否允许自动重放由请求的 `replayPolicy` 决定。
    case post = "POST"
    /// 提交资源的部分更新；使用此方法本身不代表请求具备幂等性。
    case patch = "PATCH"
}

/// 请求遇到指定传输故障时允许采用的自动重放策略。
///
/// 每次 `HTTPClient.send` 最多额外尝试一次；HTTP 状态码和业务错误不触发自动重试。
public enum HTTPReplayPolicy: Sendable, Equatable {
    /// 禁止自动重放，即使故障属于暂时性网络错误。
    case never
    /// 仅对 GET 的超时、连接中断、无法连接主机、找不到主机或 DNS 查询失败额外尝试一次。
    case readOnce
    /// 对带有正文的 POST／PATCH，仅在超时或连接中断时额外尝试一次。
    ///
    /// - Parameter operationID: 服务端用于去重的业务动作 ID；调用方须将它写入实际业务请求。
    ///   网络层不将此值自动写入请求头或正文，也不验证服务端是否支持去重。
    case idempotentWriteOnce(operationID: UUID)
}

/// 一次 HTTP 请求的不可变内存快照，包含地址、原始正文和发送策略。
///
/// 初始化只保存输入，发送时才校验参数。正文和请求头可能包含凭据；描述信息会脱敏，
/// 但读取属性仍可获得原始内容，调用方不得将其写入日志或未加密的持久存储。
public struct HTTPRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 请求地址；发送时按传输安全策略校验 scheme、主机、端口及 URL 中的认证信息。
    public let url: URL
    /// 请求方法，默认值为 `.get`。
    public let method: HTTPMethod
    /// 原始请求头，默认空字典；字段名与值在发送时校验，不在初始化时规范化。
    ///
    /// 通过 `HTTPClient` 发送时，所有大小写形式的 X-Request-ID 会被替换为当次请求 ID。
    public let headers: [String: String]
    /// 原始请求正文字节，默认 `nil`；`nil` 表示无正文，与空 Data 有区别。
    ///
    /// 自动重放保持这些字节不变；GET 要求此值为 `nil`。
    public let body: Data?
    /// 单次请求的超时间隔，单位为秒，默认 15；有效范围为大于 0 且不超过 60 的有限值。
    ///
    /// 交由 URLSession 解释，不是包含重试等待在内的整个业务动作截止时间。
    public let timeout: TimeInterval
    /// 允许的响应字节上限，默认 64 KiB，有效范围为 1～16 MiB。
    ///
    /// 原生传输同时检查已知响应长度和实际接收数据，HTTPClient 还会检查最终正文大小。
    public let maximumResponseBytes: Int
    /// 传输故障后的自动重放策略，默认 `.never`；不控制调用方主动重新发送。
    public let replayPolicy: HTTPReplayPolicy

    /// 创建请求快照，保留调用方提供的正文和策略。
    ///
    /// - Parameters:
    ///   - url: 目标资源地址；发送时须通过传输安全策略校验。
    ///   - method: HTTP 方法，默认 `.get`。
    ///   - headers: 请求头，默认空字典；应避免大小写不同但语义相同的重复字段。
    ///   - body: 原始正文，默认 `nil`；GET 不得设置。
    ///   - timeout: 单次请求超时间隔，单位为秒，默认 15，有效范围为 (0, 60]。
    ///   - maximumResponseBytes: 响应字节上限，默认 64 KiB，最大 16 MiB。
    ///   - replayPolicy: 自动重放策略，默认不重放。
    public init(url: URL, method: HTTPMethod = .get, headers: [String: String] = [:], body: Data? = nil,
                timeout: TimeInterval = 15, maximumResponseBytes: Int = 64 * 1024, replayPolicy: HTTPReplayPolicy = .never) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
        self.timeout = timeout; self.maximumResponseBytes = maximumResponseBytes; self.replayPolicy = replayPolicy
    }

    /// 只显示请求方法的脱敏说明，不包含地址、请求头或正文。
    public var description: String { "HTTPRequest(\(method.rawValue), content redacted)" }
    /// 与 `description` 相同的脱敏调试说明。
    public var debugDescription: String { description }

    /// 构造 URLRequest 并校验方法、正文、请求头及数值范围。
    ///
    /// 此步骤不校验传输安全策略，也不发送请求。
    ///
    /// - Throws: 输入不符合约束时抛出 `NetworkError.invalidRequest`。
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

/// 一次 HTTP 传输返回的状态、响应头和正文字节，不解释业务成功或失败。
///
/// 正文可能包含会话或用户资料，仅描述信息脱敏；调用方仍需按数据用途控制保存与展示。
public struct HTTPResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// HTTP 状态码；初始化时原样保存，不验证取值范围。
    public let statusCode: Int
    /// 响应头字段；字段名保持提供方给出的形式，查找时可使用 `header(_:)` 忽略大小写。
    public let headers: [String: String]
    /// 响应的完整正文字节；原生 URLSession 传输交付接收完成后的数据，不解析业务格式。
    public let body: Data
    /// 创建响应值，原样保存状态、头字段和正文。
    ///
    /// - Parameters:
    ///   - statusCode: HTTP 状态码，由业务层判断是否符合预期。
    ///   - headers: 响应头，默认空字典，不在初始化时合并大小写不同的字段。
    ///   - body: 响应正文，默认空 Data。
    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode; self.headers = headers; self.body = body
    }
    /// 按不区分大小写的字段名读取一个响应头。
    ///
    /// - Parameter name: HTTP 头字段名。
    /// - Returns: 匹配字段的值；缺失时为 `nil`。若字典包含多个大小写变体，返回顺序不作保证。
    public func header(_ name: String) -> String? {
        headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }
    /// 只显示状态码的脱敏说明，不包含响应头或正文。
    public var description: String { "HTTPResponse(status: \(statusCode), content redacted)" }
    /// 与 `description` 相同的脱敏调试说明。
    public var debugDescription: String { description }
}

/// 网络层可识别的失败原因，不附带 URL、请求正文或底层错误的 userInfo。
public enum NetworkError: Error, Sendable, Equatable {
    /// 请求数值范围、方法与正文组合、头字段或 URL 结构不符合要求。
    case invalidRequest
    /// URL 的 scheme 或 HTTP 回环地址不符合当前传输安全策略。
    case insecureURL
    /// URLSession 返回的响应无法表示为 HTTPURLResponse。
    case nonHTTPResponse
    /// 已知响应长度或接收的正文超过上限。
    ///
    /// - Parameter limit: 当前请求允许的最大响应字节数。
    case responseTooLarge(limit: Int)
    /// 系统网络操作失败，仅保留 URLError 的代码。
    ///
    /// - Parameter code: 底层网络错误代码；标准传输会将取消单独转换为 `CancellationError`。
    case transport(code: URLError.Code)
    /// 底层失败无法映射为已知网络错误；原始错误内容不向上传递。
    case transportFailed
}

/// 允许发起请求的 URL 安全策略；本类型只校验地址，不执行证书校验。
///
/// 原生传输的 TLS 校验由 URLSession 负责。HTTP 例外仅限 Debug 的 macOS 或模拟器虚构数据。
public enum TransportSecurityPolicy: Sendable, Equatable {
    /// 仅接受结构合法的 HTTPS 地址。
    case httpsOnly
    /// 接受 HTTPS，并在 Debug macOS／模拟器额外接受字面回环 HTTP 地址。
    ///
    /// HTTP 主机只允许 127.0.0.1 或 ::1，不接受 localhost；Release 和真机不开放此例外。
    case debugLoopbackForFictionalData

    /// 检查地址是否满足 URL 结构要求及当前 scheme 策略。
    ///
    /// 禁止 URL 用户名、密码和片段；显式端口必须为 1～65535。此方法不检查服务是否可达。
    ///
    /// - Parameter url: 待发送的地址。
    /// - Throws: 结构无效时为 `NetworkError.invalidRequest`，策略不允许时为 `NetworkError.insecureURL`。
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

/// 执行单次 HTTP 请求的可注入传输边界。
///
/// 实现方负责响应任务取消、限制接收数据并遵守配置的传输安全要求，不得自行重试。
/// 返回任意 HTTP 状态时应保留响应，由上层解释业务结果。
public protocol HTTPTransport: Sendable {
    /// 发送一次请求并返回完整响应，不在传输内部自动重放。
    ///
    /// - Parameter request: 本次发送的不可变请求快照，含响应上限与超时约束。
    /// - Returns: HTTP 状态、头字段和原始响应正文。
    /// - Throws: 取消应以 `CancellationError` 结束；其他失败由实现报告，HTTPClient 会进行错误映射。
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
