import AzureFishAPI

/// 应用层注入点，复用 AccountAPI 的准备、执行和单次传输重试策略。
protocol AccountServicing: Sendable {
    var api: AccountAPI { get }
}
