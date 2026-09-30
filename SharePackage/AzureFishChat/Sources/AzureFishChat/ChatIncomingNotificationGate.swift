/// 前台切换与同步基线隔离。旧前台周期启动的请求不能在新周期发出提醒。
struct ChatIncomingNotificationGate: Sendable {
    struct Pull: Sendable {
        /// 补拉开始时的提醒门控代次。
        let generation: Int
        /// 补拉开始时是否已满足前台和基线条件。
        let mayNotify: Bool
    }
    /// 是否允许前台提醒，初始为 false。
    private(set) var enabled = false
    /// 每次提醒开关变化时递增的代次，用于拒绝跨前台周期的结果。
    private var generation = 0
    /// 本轮前台是否仍需先完成一次不提醒的基线补拉，初始为 true。
    private var needsBaseline = true

    /// 更新提醒开关；实际变化时递增代次并要求重新建立基线。
    mutating func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        generation += 1
        needsBaseline = true
    }
    /// 捕获本次补拉的提醒资格；无检查点或尚需基线时禁止该轮提醒。
    func begin(hasCheckpoint: Bool) -> Pull {
        .init(generation: generation, mayNotify: enabled && !needsBaseline && hasCheckpoint)
    }
    /// 接纳当前前台周期的完成结果并消费基线状态，返回该轮是否可通知。
    mutating func complete(_ pull: Pull) -> Bool {
        guard pull.generation == generation else { return false }
        needsBaseline = false
        return enabled && pull.mayNotify
    }
}
