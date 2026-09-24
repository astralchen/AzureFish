import Foundation

/// 重试之间的等待规则；序号从 1 开始，首次执行不使用此规则。
/// 自定义规则只负责本地等待时间，是否继续由次数、取消状态及重试决策决定。
enum RetryDelay<Interval: Sendable>: Sendable {
    /// 立即再次尝试，仍会检查任务取消。
    case immediate
    /// 每次失败退出后等待相同间隔。
    case fixed(Interval)
    /// 未加抖动的间隔逐次乘以倍率，达到 maximum 后保持上限。
    case exponential(initial: Interval, multiplier: Double = 2, maximum: Interval, jitter: RetryJitter = .none)
    /// 同步计算下一次等待；参数依次为重试序号及本次操作错误。
    case custom(@Sendable (_ retryIndex: Int, _ error: any Error) -> Interval)
}

/// 指数退避的随机分散方式；不会影响下一轮未加抖动的间隔。
enum RetryJitter: Sendable {
    case none
    /// 在零至本轮间隔之间取值；初始间隔此时表示首轮等待上限。
    case full
}

/// 一次操作失败的上下文；failedAttempt 从 1 开始，包含首次执行。
struct RetryContext: Sendable {
    let error: any Error
    let failedAttempt: Int
}

/// 策略仅决定是否继续及本次最短等待；取消和次数上限始终由执行器控制。
enum RetryDecision<Interval: Sendable & AdditiveArithmetic>: Sendable {
    /// 保留本次操作错误，不再计算退避或等待。
    case stop
    /// 最终间隔取本地退避（含抖动）与 minimumDelay 的较大值，不改变后续退避进度。
    case retry(minimumDelay: Interval = .zero)
}

/// 布尔筛选兼容入口；true 映射为零最短等待的重试，false 映射为停止。
@available(iOS 16.0, *)
nonisolated func withTaskRetry<C: Clock, Success: Sendable>(
    maxAttempts: Int,
    delay: RetryDelay<C.Instant.Duration>,
    tolerance: C.Instant.Duration? = nil,
    clock: C = .continuous,
    shouldRetry: @escaping @Sendable (any Error) -> Bool,
    @_inheritActorContext operation: sending @escaping @isolated(any) () async throws -> Success
) async throws -> Success {
    try await withTaskRetry(maxAttempts: maxAttempts, delay: delay, tolerance: tolerance, clock: clock, policy: {
        shouldRetry($0.error) ? .retry() : .stop
    }, operation: operation)
}

/// 有限次数顺序重试，保持操作自身的 Actor 隔离；maxAttempts 包含首次执行。
/// 取消错误绝不进入 policy；策略停止或次数耗尽时原样抛出本次操作错误。
/// 动态 minimumDelay 非法时安全停止；本地策略配置错误仍触发前置条件失败。
/// Clock 和 tolerance 用法与 withTaskTimeout 一致，总期限由外层超时控制。
@available(iOS 16.0, *)
nonisolated func withTaskRetry<C: Clock, Success: Sendable>(
    maxAttempts: Int,
    delay: RetryDelay<C.Instant.Duration>,
    tolerance: C.Instant.Duration? = nil,
    clock: C = .continuous,
    policy: @Sendable (RetryContext) -> RetryDecision<C.Instant.Duration>,
    @_inheritActorContext operation: sending @escaping @isolated(any) () async throws -> Success
) async throws -> Success {
    let schedule = RetryDelaySchedule(delay: delay, validate: { precondition($0 >= .zero) }, scale: retryScaleDuration)
    return try await runWithTaskRetry(maxAttempts: maxAttempts, schedule: schedule, policy: policy,
                                      isValidMinimumDelay: { $0 >= .zero }, operation: operation) {
        try await Task.sleep(for: $0, tolerance: tolerance, clock: clock)
    }
}

/// iOS 15 布尔筛选兼容入口，与 Clock 入口使用同一决策执行核心。
nonisolated func withTaskRetry<Success: Sendable>(
    maxAttempts: Int,
    delaySeconds: RetryDelay<TimeInterval>,
    shouldRetry: @escaping @Sendable (any Error) -> Bool,
    @_inheritActorContext operation: sending @escaping @isolated(any) () async throws -> Success
) async throws -> Success {
    try await withTaskRetry(maxAttempts: maxAttempts, delaySeconds: delaySeconds, policy: {
        shouldRetry($0.error) ? .retry() : .stop
    }, operation: operation)
}

/// iOS 15 秒数决策入口；间隔必须有限、非负且可安全转换为纳秒。
/// 动态 minimumDelay 超出范围时保留操作错误，其他语义与 Clock 入口一致。
nonisolated func withTaskRetry<Success: Sendable>(
    maxAttempts: Int,
    delaySeconds: RetryDelay<TimeInterval>,
    policy: @Sendable (RetryContext) -> RetryDecision<TimeInterval>,
    @_inheritActorContext operation: sending @escaping @isolated(any) () async throws -> Success
) async throws -> Success {
    let schedule = RetryDelaySchedule(delay: delaySeconds, validate: validateRetrySeconds, scale: retryScaleSeconds)
    return try await runWithTaskRetry(maxAttempts: maxAttempts, schedule: schedule, policy: policy,
                                      isValidMinimumDelay: isValidRetrySeconds, operation: operation) {
        try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }
}

/// 等待置于 catch 之外：Clock 的错误或取消不能被当作操作失败再次重试。
private nonisolated func runWithTaskRetry<Interval: Sendable & Comparable & AdditiveArithmetic, Success: Sendable>(
    maxAttempts: Int,
    schedule: RetryDelaySchedule<Interval>,
    policy: @Sendable (RetryContext) -> RetryDecision<Interval>,
    isValidMinimumDelay: @Sendable (Interval) -> Bool,
    operation: sending @escaping @isolated(any) () async throws -> Success,
    sleep: @Sendable (Interval) async throws -> Void
) async throws -> Success {
    precondition(maxAttempts > 0)
    try Task.checkCancellation()
    let operation = RetryOperation(operation)
    var schedule = schedule
    var attempt = 1
    while true {
        try Task.checkCancellation()
        let interval: Interval
        do {
            return try await operation.run()
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            try Task.checkCancellation()
            guard attempt < maxAttempts else { throw error }
            let decision = policy(RetryContext(error: error, failedAttempt: attempt))
            // 即使策略返回 stop，策略执行期间发生的父任务取消也优先终止。
            try Task.checkCancellation()
            guard case .retry(let minimumDelay) = decision, isValidMinimumDelay(minimumDelay) else { throw error }
            interval = schedule.next(retryIndex: attempt, error: error, minimumDelay: minimumDelay)
        }
        try Task.checkCancellation()
        if interval > .zero { try await sleep(interval) }
        attempt += 1
    }
}

/// 单一所有者接收独占捕获并顺序重复调用；不为每次尝试重新转移闭包。
private actor RetryOperation<Success: Sendable> {
    private let operation: @isolated(any) () async throws -> Success

    init(_ operation: sending @escaping @isolated(any) () async throws -> Success) {
        self.operation = operation
    }

    func run() async throws -> Success {
        try Task.checkCancellation()
        return try await operation()
    }
}

/// 每次 withTaskRetry 独立持有进度，复用同一策略不会共享退避状态。
/// 保持内部可见性，以便测试注入确定性的随机来源和时间运算。
struct RetryDelaySchedule<Interval: Sendable & Comparable & AdditiveArithmetic>: Sendable {
    private let delay: RetryDelay<Interval>
    private let validate: @Sendable (Interval) -> Void
    private let scale: @Sendable (Interval, Double, Interval) -> Interval
    private let randomUnit: @Sendable () -> Double
    private var previous: Interval?

    init(
        delay: RetryDelay<Interval>,
        validate: @escaping @Sendable (Interval) -> Void,
        scale: @escaping @Sendable (Interval, Double, Interval) -> Interval,
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.delay = delay
        self.validate = validate
        self.scale = scale
        self.randomUnit = randomUnit
        switch delay {
        case .immediate, .custom: break
        case .fixed(let interval): validate(interval)
        case .exponential(let initial, let multiplier, let maximum, _):
            validate(initial)
            validate(maximum)
            precondition(multiplier.isFinite && multiplier >= 1)
            precondition(maximum >= initial)
        }
    }

    /// 仅在一次可重试失败之后调用一次；指数进度与随机抖动互相独立。
    /// minimumDelay 已由执行器校验；在抖动之后合并，不写入指数进度。
    mutating func next(retryIndex: Int, error: any Error, minimumDelay: Interval = .zero) -> Interval {
        let interval: Interval
        switch delay {
        case .immediate: interval = .zero
        case .fixed(let value): interval = value
        case .custom(let calculate): interval = calculate(retryIndex, error)
        case .exponential(let initial, let multiplier, let maximum, let jitter):
            let upper = previous.map { scale($0, multiplier, maximum) } ?? initial
            previous = upper
            switch jitter {
            case .none: interval = upper
            case .full:
                let unit = randomUnit()
                precondition(unit.isFinite && (0...1).contains(unit))
                interval = scale(upper, unit, upper)
            }
        }
        validate(interval)
        return max(interval, minimumDelay)
    }
}

/// 与超时秒数入口使用同一安全范围，避免 UInt64 转换越界。
private nonisolated func validateRetrySeconds(_ interval: TimeInterval) {
    precondition(isValidRetrySeconds(interval))
}

/// 动态策略值采用非崩溃校验；固定配置沿用相同范围的 precondition。
private nonisolated func isValidRetrySeconds(_ interval: TimeInterval) -> Bool {
    interval.isFinite && interval >= 0 && interval < Double(UInt64.max) / 1_000_000_000
}

/// 先判断封顶再乘，避免极大倍率产生无穷值。
nonisolated func retryScaleSeconds(_ interval: TimeInterval, _ factor: Double, _ maximum: TimeInterval) -> TimeInterval {
    guard interval > 0, factor > 0 else { return 0 }
    if factor >= 1, interval >= maximum / factor { return maximum }
    return min(maximum, interval * factor)
}

/// DurationProtocol 只有整数缩放：按倍率的二进制位运算，始终不转换时间单位。
/// 在每次加倍或相加前判断上限，不计算可能溢出的乘积；精度由 Duration 类型决定。
@available(iOS 16.0, *)
nonisolated func retryScaleDuration<D: DurationProtocol>(_ interval: D, _ factor: Double, _ maximum: D) -> D {
    guard interval > .zero, factor > 0 else { return .zero }
    if factor < 1 { return retryDurationFraction(interval, factor) }
    var value = interval
    // 有限 Double 的 exponent 至多为 1023，且达到上限后立即返回。
    for _ in 0..<factor.exponent {
        if value >= maximum - value { return maximum }
        value += value
    }
    let fraction = retryDurationFraction(value, factor.significand - 1)
    if fraction >= maximum - value { return maximum }
    return value + fraction
}

/// 按二进制小数从低位到高位取中点，避免分别截断各位导致累计精度损失。
/// result + (interval - result) / 2 不会计算可能溢出的 result + interval。
@available(iOS 16.0, *)
private nonisolated func retryDurationFraction<D: DurationProtocol>(_ interval: D, _ fraction: Double) -> D {
    var remainder = fraction
    var bits: [Bool] = []
    while remainder > 0 {
        remainder *= 2
        let bit = remainder >= 1
        bits.append(bit)
        if bit { remainder -= 1 }
    }
    var result: D = .zero
    for bit in bits.reversed() {
        if bit { result += (interval - result) / 2 }
        else { result /= 2 }
    }
    return result
}
