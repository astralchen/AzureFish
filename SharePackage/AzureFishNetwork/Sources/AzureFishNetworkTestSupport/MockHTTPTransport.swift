import Foundation
import AzureFishNetwork

/// 记录请求并由注入闭包产生响应的内存测试传输。
///
/// 仅使用虚构数据：历史记录包含原始请求头和正文，并保留至实例释放。此实现不执行真实网络、
/// 安全地址校验、响应大小限制或重试，适合通过 HTTPClient 测试上层策略。
public actor MockHTTPTransport: HTTPTransport {
    /// 为一次请求产生模拟响应的异步处理器。
    ///
    /// 第一个参数为原始请求，第二个参数为当前实例从 1 开始的发送序号；序号在调用前确定。
    /// 闭包不承诺运行在主 Actor，允许挂起或抛错，应配合任务取消；每次 send 只调用一次。
    public typealias Handler = @Sendable (HTTPRequest, Int) async throws -> HTTPResponse
    private let handler: Handler
    private var history: [HTTPRequest] = []
    /// 创建测试传输并持有响应处理器，初始历史记录为空。
    ///
    /// - Parameter handler: 每次 send 调用的处理器；可根据请求和发送序号返回响应或抛出测试错误。
    public init(handler: @escaping Handler) { self.handler = handler }
    /// 截至读取时按接收顺序记录的请求快照；初始为空，失败的请求也会保留。
    ///
    /// 读取受 Actor 隔离约束；外部需 await。返回的数组不会随后续发送自动更新。
    public var requests: [HTTPRequest] { history }
    /// 记录请求，调用一次处理器，并在处理器返回后再次检查取消。
    ///
    /// 处理器挂起期间，Actor 可接收其他发送；历史记录顺序不代表完成顺序。
    ///
    /// - Parameter request: 本次测试输入，未经规范化或脱敏即加入历史记录。
    /// - Returns: 处理器产生的响应，不在此处检查正文上限。
    /// - Throws: `CancellationError` 或处理器原样抛出的错误。
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        history.append(request)
        let response = try await handler(request, history.count)
        try Task.checkCancellation()
        return response
    }
}
