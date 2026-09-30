import Foundation
@testable import AzureFishNetwork
import AzureFishNetworkTestSupport
import Testing

/// 在不修改进程全局配置的情况下验证诊断开关、事件和敏感数据边界。
@Suite("网络诊断日志")
struct NetworkDiagnosticsTests {
    /// 包含虚构敏感标记的诊断测试地址，不用于真实账号。
    private let url = URL(string: "https://fictional.invalid/private-secret?token=query-secret")!

    /// 验证诊断开关只接受唯一参数及小写 true。
    @Test func launchArgumentsRequireUniqueLiteralTrue() {
        let flag = "-AzureFishNetworkLogging"
        #if DEBUG
        #expect(NetworkDiagnostics.isEnabled(arguments: ["app", flag, "true"]))
        #else
        #expect(!NetworkDiagnostics.isEnabled(arguments: ["app", flag, "true"]))
        #endif
        for arguments in [["app"], ["app", flag], [flag, "false"], [flag, "TRUE"], [flag, "1"],
                          [flag, "true", flag, "true"], [flag, "true", flag], [flag + "=true"]] {
            #expect(!NetworkDiagnostics.isEnabled(arguments: arguments))
        }
    }

    /// 验证关闭诊断时不求值日志内容或采集时钟。
    @Test func disabledLoggingDoesNotEvaluateMessagesOrClock() {
        let recorder = Recorder()
        let diagnostics = NetworkDiagnostics(enabled: false, sink: recorder.append)
        var evaluated = false
        func message() -> String { evaluated = true; return "secret" }
        diagnostics.log(message())
        #expect(!evaluated)
        #expect(diagnostics.startTime() == nil)
        #expect(recorder.messages.isEmpty)
    }

    /// 验证诊断记录响应而不改变 HTTP 状态语义。
    @Test(arguments: [200, 503]) func responsesAreLoggedWithoutChangingHTTPStatus(status: Int) async throws {
        let recorder = Recorder()
        let transport = MockHTTPTransport { _, _ in
            HTTPResponse(statusCode: status, headers: ["Set-Cookie": "cookie-secret"], body: Data("response-secret".utf8))
        }
        let client = HTTPClient(transport: transport, diagnostics: recorder.diagnostics)
        let request = HTTPRequest(url: url, method: .post, headers: ["Authorization": "Bearer token-secret", "X-Request-ID": "caller-secret"],
                                  body: Data("password-secret".utf8), replayPolicy: .idempotentWriteOnce(operationID: UUID()))
        let response = try await client.send(request)
        #expect(response.statusCode == status)
        #expect(response.body == Data("response-secret".utf8))
        #expect(recorder.events == ["send", "response"])
        let messages = recorder.messages.joined(separator: "\n")
        #expect(messages.contains("status=\(status)"))
        #expect(messages.contains("requestBytes=15"))
        #expect(messages.contains("responseBytes=15"))
        #expect(messages.contains("elapsedMs="))
        #expect(!messages.contains("secret"))
        #expect(!messages.contains("fictional.invalid"))
        let history = await transport.requests
        #expect(history.count == 1)
        let id = try #require(history.first?.headers["X-Request-ID"])
        #expect(recorder.messages.allSatisfy { $0.contains("requestID=\(id)") })
    }

    /// 验证重试诊断包含两次尝试及不同请求身份。
    @Test func retryLogsBothAttemptsWithFreshRequestIDs() async throws {
        let recorder = Recorder()
        let transport = MockHTTPTransport { _, count in
            if count == 1 { throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "underlying-secret"]) }
            return HTTPResponse(statusCode: 201)
        }
        let client = HTTPClient(transport: transport, waitBeforeRetry: {}, diagnostics: recorder.diagnostics)
        let operationID = UUID()
        let request = HTTPRequest(url: url, method: .post, body: Data([1, 2, 3]), replayPolicy: .idempotentWriteOnce(operationID: operationID))
        #expect(try await client.send(request).statusCode == 201)
        #expect(recorder.events == ["send", "retry", "send", "response"])
        let history = await transport.requests
        #expect(history.count == 2)
        #expect(history[0].body == history[1].body)
        let first = try #require(history[0].headers["X-Request-ID"])
        let second = try #require(history[1].headers["X-Request-ID"])
        #expect(first != second)
        #expect(recorder.messages[1].contains("requestID=\(first) attempt=1 nextAttempt=2"))
        #expect(recorder.messages[2].contains("requestID=\(second) attempt=2"))
        let output = recorder.messages.joined()
        #expect(output.contains("error=transport(\(URLError.timedOut.rawValue))"))
        #expect(!output.contains("secret"))
        #expect(!output.lowercased().contains(operationID.uuidString.lowercased()))
    }

    /// 验证请求校验失败会记录诊断且不会调用传输。
    @Test func validationFailureNeverSends() async {
        let recorder = Recorder()
        let transport = MockHTTPTransport { _, _ in Issue.record("Unexpected send"); return HTTPResponse(statusCode: 200) }
        let client = HTTPClient(transport: transport, diagnostics: recorder.diagnostics)
        await #expect(throws: NetworkError.invalidRequest) {
            try await client.send(HTTPRequest(url: url, headers: ["Authorization": "secret\r\nvalue"]))
        }
        #expect(await transport.requests.isEmpty)
        #expect(recorder.events == ["failure"])
        #expect(recorder.messages[0].contains("attempt=0 phase=validation error=invalidRequest"))
        #expect(!recorder.messages[0].contains("secret"))
    }

    /// 验证最终传输失败次数有界且诊断内容脱敏。
    @Test func finalTransportFailureIsBoundedAndRedacted() async {
        let recorder = Recorder()
        let transport = MockHTTPTransport { _, _ in throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: "url-secret"]) }
        let client = HTTPClient(transport: transport, waitBeforeRetry: {}, diagnostics: recorder.diagnostics)
        await #expect(throws: NetworkError.transport(code: .timedOut)) {
            try await client.send(HTTPRequest(url: url, replayPolicy: .readOnce))
        }
        #expect(await transport.requests.count == 2)
        #expect(recorder.events == ["send", "retry", "send", "failure"])
        #expect(!recorder.messages.joined().contains("secret"))
    }

    /// 验证响应超限诊断在已接收响应事件之后记录。
    @Test func responseLimitFailureFollowsResponseEvent() async {
        let recorder = Recorder()
        let client = HTTPClient(transport: MockHTTPTransport { _, _ in HTTPResponse(statusCode: 200, body: Data([1, 2])) },
                                diagnostics: recorder.diagnostics)
        await #expect(throws: NetworkError.responseTooLarge(limit: 1)) {
            try await client.send(HTTPRequest(url: url, maximumResponseBytes: 1))
        }
        #expect(recorder.events == ["send", "response", "failure"])
        #expect(recorder.messages.last?.contains("error=responseTooLarge") == true)
    }

    /// 验证重试等待错误被记录并原样向上传递。
    @Test func retryWaitErrorIsLoggedAndPreserved() async {
        let recorder = Recorder()
        let transport = MockHTTPTransport { _, _ in throw URLError(.networkConnectionLost) }
        let client = HTTPClient(transport: transport, waitBeforeRetry: { throw SecretError() }, diagnostics: recorder.diagnostics)
        await #expect(throws: SecretError.self) {
            try await client.send(HTTPRequest(url: url, replayPolicy: .readOnce))
        }
        #expect(await transport.requests.count == 1)
        #expect(recorder.events == ["send", "retry", "failure"])
        #expect(recorder.messages.last?.contains("phase=retryWait error=unknown") == true)
        #expect(!recorder.messages.joined().contains("secret"))
    }

    /// 验证传输或重试等待期间取消均被记录且不继续重试。
    @Test(arguments: [false, true]) func cancellationIsLoggedWithoutRetryingAgain(duringWait: Bool) async {
        let recorder = Recorder()
        let transport = MockHTTPTransport { _, _ in
            if duringWait { throw URLError(.timedOut) }
            throw CancellationError()
        }
        let client = HTTPClient(transport: transport, waitBeforeRetry: { throw CancellationError() }, diagnostics: recorder.diagnostics)
        await #expect(throws: CancellationError.self) {
            try await client.send(HTTPRequest(url: url, replayPolicy: .readOnce))
        }
        #expect(await transport.requests.count == 1)
        #expect(recorder.events == (duringWait ? ["send", "retry", "cancelled"] : ["send", "cancelled"]))
    }

    /// 验证预先取消的任务不提交传输。
    @Test func preCancelledTaskDoesNotSend() async {
        let recorder = Recorder()
        let transport = MockHTTPTransport { _, _ in Issue.record("Unexpected send"); return HTTPResponse(statusCode: 200) }
        let client = HTTPClient(transport: transport, diagnostics: recorder.diagnostics)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(HTTPRequest(url: url))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.isEmpty)
        #expect(recorder.events == ["cancelled"])
    }
}

private struct SecretError: Error, CustomStringConvertible {
    /// 包含虚构秘密标记的底层错误描述，用于验证诊断不泄漏原始错误。
    var description: String { "underlying-secret" }
}

/// 用锁隔离同步日志接收器，允许多个请求并发写入测试记录。
private final class Recorder: @unchecked Sendable {
    /// 保护并发诊断记录及读取的锁。
    private let lock = NSLock()
    /// 按实际追加顺序保存的诊断消息。
    private var storage: [String] = []
    /// 启用诊断并将输出交给当前记录器的测试实例。
    var diagnostics: NetworkDiagnostics { NetworkDiagnostics(enabled: true, sink: append) }
    /// 在锁保护下追加一条诊断消息。
    func append(_ message: String) { lock.lock(); defer { lock.unlock() }; storage.append(message) }
    /// 截至读取时的诊断消息数组快照。
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    /// 从每条诊断的首字段提取事件名，保留消息顺序。
    var events: [String] { messages.map { String($0.split(separator: " ")[0].dropFirst("event=".count)) } }
}
