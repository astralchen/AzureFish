import Foundation
import AzureFishNetwork

/// 固定的服务环境；切换实例不会清理会话，退出与账号代次由 App 协调。
public struct APIEnvironment: Sendable, Equatable {
    public let identifier: String
    public let baseURL: URL
    public let security: TransportSecurityPolicy

    /// 创建 HTTPS 环境；baseURL 必须为不含认证、查询、片段或额外路径的服务根地址。
    public init(identifier: String, baseURL: URL) throws {
        try self.init(identifier: identifier, baseURL: baseURL, security: .httpsOnly)
    }

    /// 仅供 Debug macOS／模拟器中的虚构账号，不能在真机或 Release 开放 HTTP。
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

    func url(path: String) -> URL { baseURL.appendingPathComponent(path) }
}
