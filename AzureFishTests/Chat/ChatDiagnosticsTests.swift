import Testing
@testable import AzureFish

/// 日志必须同时具备显式参数和 true 值，避免诊断在日常启动时意外开启。
struct ChatDiagnosticsTests {
    @Test(arguments: [
        ["Demo"],
        ["Demo", "-chat-debug-logs"],
        ["Demo", "-chat-debug-logs", "false"],
        ["Demo", "-chat-debug-logs", "1"],
        ["Demo", "-chat-debug-logs", "TRUE"],
        ["Demo", "-other", "true"],
        ["Demo", "-chat-debug-logs", "-other", "true"],
        ["Demo", "-chat-debug-logs", "true", "-chat-debug-logs", "false"]
    ])
    func disabledWithoutExplicitTrue(arguments: [String]) {
        #expect(!ChatDiagnostics.isEnabled(arguments: arguments))
    }

    @Test
    func enabledWithExplicitTrue() {
        #expect(ChatDiagnostics.isEnabled(arguments: ["Demo", "-chat-debug-logs", "true"]))
    }
}
