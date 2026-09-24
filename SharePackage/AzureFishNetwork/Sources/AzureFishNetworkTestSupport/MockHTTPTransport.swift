import Foundation
import AzureFishNetwork

/// 仅供虚构数据测试的内存传输；记录原始请求以便断言重试字节，不用于生产诊断。
public actor MockHTTPTransport: HTTPTransport {
    public typealias Handler = @Sendable (HTTPRequest, Int) async throws -> HTTPResponse
    private let handler: Handler
    private var history: [HTTPRequest] = []
    public init(handler: @escaping Handler) { self.handler = handler }
    public var requests: [HTTPRequest] { history }
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        history.append(request)
        let response = try await handler(request, history.count)
        try Task.checkCancellation()
        return response
    }
}
