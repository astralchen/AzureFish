import Testing

/// 各主题用例通过同目录的 DemoTests+*.swift 扩展组织。
/// 保持单一串行套件，避免操作窗口、语言及 UIKit 状态的用例并发执行。
@MainActor
@Suite(.serialized)
struct DemoTests {}
