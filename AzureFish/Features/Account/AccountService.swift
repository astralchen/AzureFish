import AzureFishAPI
import Foundation

/// 应用层注入点，复用 AccountAPI 的准备、执行和单次传输重试策略。
protocol AccountServicing: Sendable {
    var api: AccountAPI { get }
}
struct LiveAccountService: AccountServicing {
    let api: AccountAPI
    /// 回环服务只在 Debug 模拟器且明确启用时可用，发布与真机没有默认账号服务。
    static func configured(arguments: [String] = ProcessInfo.processInfo.arguments) -> LiveAccountService? {
        #if DEBUG && targetEnvironment(simulator)
        guard arguments.contains("-account-local-development"), let environment = try? APIEnvironment.localTesting() else { return nil }
        return LiveAccountService(api: AccountAPI(environment: environment))
        #else
        return nil
        #endif
    }
}

/// 保留原始输入供同一次失败提交重试，生命周期限于当前表单内存。
struct AuthenticationInput: Equatable {
    let register: Bool
    let account: String
    let password: String
    let nickname: String
}
