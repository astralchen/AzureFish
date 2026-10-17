import AzureFishAPI
import Foundation

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
