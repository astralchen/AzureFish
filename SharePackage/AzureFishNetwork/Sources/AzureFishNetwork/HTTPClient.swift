import Foundation

/// 按安全策略发送请求，并对明确允许的暂时性传输失败执行有界重试。
///
/// 请求和响应只在内存中流转，HTTP 状态码不触发重试。实例不维护请求队列或账号会话；
/// 注入的传输对象由实例持有，业务层负责协调共享状态。
/// Debug 启动参数 `-AzureFishNetworkLogging true` 可开启脱敏诊断，Release 始终关闭。
public struct HTTPClient: Sendable {
    private let transport: any HTTPTransport
    private let diagnostics: NetworkDiagnostics
    private let security: TransportSecurityPolicy
    private let waitBeforeRetry: @Sendable () async throws -> Void

    /// 创建客户端并指定单次传输实现、安全策略和重试等待操作。
    ///
    /// - Parameters:
    ///   - transport: 单次请求的传输实现；`nil` 时创建采用相同安全策略的 URLSessionHTTPTransport。
    ///   - security: 每次发送前使用的 URL 校验策略，默认仅允许 HTTPS。
    ///   - waitBeforeRetry: 首次传输失败且允许重试时等待的异步操作，默认等待 200 毫秒。
    ///     每次 send 至多调用一次；应响应取消，抛错时终止重试并原样向上传递错误。
    public init(transport: (any HTTPTransport)? = nil, security: TransportSecurityPolicy = .httpsOnly,
                waitBeforeRetry: @escaping @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 200_000_000) }) {
        self.init(transport: transport, security: security, waitBeforeRetry: waitBeforeRetry, diagnostics: .live)
    }

    /// 注入诊断接收器以验证事件；公开初始化始终采用进程启动配置。
    init(transport: (any HTTPTransport)? = nil, security: TransportSecurityPolicy = .httpsOnly,
         waitBeforeRetry: @escaping @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 200_000_000) },
         diagnostics: NetworkDiagnostics) {
        self.diagnostics = diagnostics
        self.transport = transport ?? URLSessionHTTPTransport(security: security)
        self.security = security; self.waitBeforeRetry = waitBeforeRetry
    }

    /// 发送请求，并在符合请求重放策略的首次传输失败后至多重试一次。
    ///
    /// 每次实际发送都会替换 X-Request-ID，其他请求字段及正文字节保持不变。返回 HTTP 错误状态
    /// 仍视为收到响应；证书错误、取消、响应超限和未知传输失败不会自动重试。
    ///
    /// 发送前、每次尝试前及接收响应后执行相应校验或取消检查；本方法不指定 UI 回调上下文，
    /// 调用方在 await 返回后处理结果。请求校验失败时不会调用传输实现。
    ///
    /// - Parameter request: 已准备的请求快照，包括单次超时、响应上限和重放策略。
    /// - Returns: 接收完成且正文未超限的响应；业务状态码由调用方判断。
    /// - Throws: 请求或传输失败对应的 `NetworkError`、任务取消对应的 `CancellationError`，
    ///   或 `waitBeforeRetry` 原样抛出的错误。
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let start = diagnostics.startTime()
        var requestID: String?
        var attemptNumber = 0
        var phase = "validation"
        do {
            try security.validate(request.url)
            _ = try request.urlRequest()
            for attempt in 0...1 {
                try Task.checkCancellation()
                attemptNumber = attempt + 1
                phase = "transport"
                let id = UUID().uuidString.lowercased()
                requestID = id
                var headers = request.headers.filter { $0.key.caseInsensitiveCompare("X-Request-ID") != .orderedSame }
                headers["X-Request-ID"] = id
                let outgoing = HTTPRequest(url: request.url, method: request.method, headers: headers, body: request.body,
                                           timeout: request.timeout, maximumResponseBytes: request.maximumResponseBytes, replayPolicy: request.replayPolicy)
                let attemptStart = diagnostics.startTime()
                diagnostics.log("event=send method=\(request.method.rawValue) requestID=\(id) attempt=\(attemptNumber) requestBytes=\(request.body?.count ?? 0)")
                do {
                    let response = try await transport.send(outgoing)
                    diagnostics.log("event=response method=\(request.method.rawValue) requestID=\(id) attempt=\(attemptNumber) status=\(response.statusCode) responseBytes=\(response.body.count) elapsedMs=\(NetworkDiagnostics.elapsedMilliseconds(since: attemptStart))")
                    try Task.checkCancellation()
                    guard response.body.count <= request.maximumResponseBytes else { throw NetworkError.responseTooLarge(limit: request.maximumResponseBytes) }
                    return response
                } catch {
                    if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    let mapped = (error as? NetworkError) ?? (error as? URLError).map { .transport(code: $0.code) } ?? .transportFailed
                    guard attempt == 0, retryAllowed(request, error: mapped) else { throw mapped }
                    diagnostics.log("event=retry method=\(request.method.rawValue) requestID=\(id) attempt=\(attemptNumber) nextAttempt=\(attemptNumber + 1) error=\(NetworkDiagnostics.errorCode(mapped)) elapsedMs=\(NetworkDiagnostics.elapsedMilliseconds(since: attemptStart))")
                    phase = "retryWait"
                    try await waitBeforeRetry()
                }
            }
            throw NetworkError.transportFailed
        } catch {
            diagnostics.log("event=\(error is CancellationError || (error as? URLError)?.code == .cancelled ? "cancelled" : "failure") method=\(request.method.rawValue) requestID=\(requestID ?? "none") attempt=\(attemptNumber) phase=\(phase) error=\(NetworkDiagnostics.errorCode(error)) elapsedMs=\(NetworkDiagnostics.elapsedMilliseconds(since: start))")
            throw error
        }
    }

    private func retryAllowed(_ request: HTTPRequest, error: NetworkError) -> Bool {
        guard case .transport(let code) = error else { return false }
        switch request.replayPolicy {
        case .never: return false
        case .readOnce:
            return request.method == .get && [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(code)
        case .idempotentWriteOnce:
            return request.method != .get && request.body != nil && [.timedOut, .networkConnectionLost].contains(code)
        }
    }
}
