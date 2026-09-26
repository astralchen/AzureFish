import Foundation
import AzureFishNetwork

/// 账号服务的不可变环境标识、根地址和传输安全策略。
///
/// 环境值参与操作作用域比较；创建或切换实例不会退出账号或清理凭据，这些生命周期由应用层协调。
public struct APIEnvironment: Sendable, Equatable {
    /// 服务环境标识，长度为 1～64 个 UTF-8 字节，只允许小写 ASCII 字母、数字、短横线和下划线。
    public let identifier: String
    /// 服务根地址；路径只能为空或 /，不得携带用户名、密码、查询或片段。
    public let baseURL: URL
    /// 本环境发送请求时采用的安全策略；公开初始化使用 `.httpsOnly`。
    public let security: TransportSecurityPolicy

    /// 创建使用 HTTPS 的服务环境，校验标识和服务根地址。
    ///
    /// - Parameters:
    ///   - identifier: 服务环境 ID；不会自动 trim 或转换大小写，须符合允许字符及长度。
    ///   - baseURL: HTTPS 根地址，可包含有效端口，但不能包含额外路径、认证、查询或片段。
    /// - Throws: 任一环境约束不满足时抛出 `APIClientError.invalidEnvironment`。
    public init(identifier: String, baseURL: URL) throws {
        try self.init(identifier: identifier, baseURL: baseURL, security: .httpsOnly)
    }

    /// 创建供 Debug macOS／模拟器虚构账号联调用的回环环境。
    ///
    /// 环境标识固定为 local-development，地址为 http://127.0.0.1；Release 和真机中构造会失败。
    ///
    /// - Parameter port: 回环服务端口，默认 8080，有效范围为 1～65535。
    /// - Returns: 允许 Debug 回环 HTTP 的环境值；不会启动或探测服务。
    /// - Throws: 端口无效或当前构建不允许回环 HTTP 时抛出 `APIClientError.invalidEnvironment`。
    public static func localTesting(port: Int = 8080) throws -> APIEnvironment {
        guard (1...65535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)") else { throw APIClientError.invalidEnvironment }
        return try APIEnvironment(identifier: "local-development", baseURL: url, security: .debugLoopbackForFictionalData)
    }

    private init(identifier: String, baseURL: URL, security: TransportSecurityPolicy) throws {
        guard !identifier.isEmpty, identifier.utf8.count <= 64,
              identifier.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.query == nil, components.path.isEmpty || components.path == "/" else { throw APIClientError.invalidEnvironment }
        do { try security.validate(baseURL) } catch { throw APIClientError.invalidEnvironment }
        self.identifier = identifier
        self.baseURL = baseURL
        self.security = security
    }

    /// 将内部接口路径追加到已校验的服务根地址，不执行请求。
    func url(path: String) -> URL { baseURL.appendingPathComponent(path) }
}
