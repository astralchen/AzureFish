/// 前台切换与同步基线隔离。旧前台周期启动的请求不能在新周期发出提醒。
struct ChatIncomingNotificationGate: Sendable {
    struct Pull: Sendable {
        let generation: Int
        let mayNotify: Bool
    }
    private(set) var enabled = false
    private var generation = 0
    private var needsBaseline = true

    mutating func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        generation += 1
        needsBaseline = true
    }
    func begin(hasCheckpoint: Bool) -> Pull {
        .init(generation: generation, mayNotify: enabled && !needsBaseline && hasCheckpoint)
    }
    mutating func complete(_ pull: Pull) -> Bool {
        guard pull.generation == generation else { return false }
        needsBaseline = false
        return enabled && pull.mayNotify
    }
}
