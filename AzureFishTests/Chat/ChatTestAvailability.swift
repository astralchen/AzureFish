import Testing

/// 聊天用例在旧系统中作为跳过项保留在测试清单中。
nonisolated enum ChatTestAvailability {
    static var isSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}
