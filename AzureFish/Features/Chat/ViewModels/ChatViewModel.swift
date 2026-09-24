//
//  ChatViewModel.swift
//  Demo
//

import AppLocalization
import Foundation

/// 管理本地聊天消息、发送尝试、模拟回复及时间线展示状态的对象。
///
/// 所有消息状态更新在主 Actor 上串行执行，异步结果通过操作身份校验后应用。
@available(iOS 16.0, *)
@MainActor
final class ChatViewModel {

    /// 描述本次发出消息应产生的模拟回复载荷。
    enum ReplyKind {
        /// 使用现有本地化文本生成回复。
        case text

        /// 使用发送时解析的文本和区域设置生成本地音频附件。
        case synthesizedAudio(text: String, locale: Locale, fallback: Attachment)

        /// 保留原文件与元数据，以独立身份模拟对方发送同类型附件。
        case attachment(Attachment)
    }

    /// 指明时间线更新来源，以便视图选择动画与滚动策略。
    enum UpdateReason: Equatable {
        /// 首次绑定时发布完整初始状态。
        case initial
        /// 首次历史准备完成，按用户是否已交互决定保持锚点或滚动到底部。
        case historyLoaded
        /// 更早的历史页插入，只保持阅读位置。
        case olderHistoryLoaded
        /// 顶部加载或错误提示变化。
        case historyStatus
        /// 当前用户追加了发出消息。
        case sentMessage
        /// 时间线追加了收到的消息。
        case receivedMessage
        /// 应用语言变化，需要重新解析展示文字。
        case localization
        /// 音频文件识别完成，需要回填气泡文字。
        case audioTranscript
        /// 附件保存反馈发生变化，需要刷新对应单元格。
        case attachmentSave
        /// 发送、送达、已读或处理状态发生变化。
        case messageStatus
        /// 删除后保留阅读位置并重新计算时间分组。
        case messageDeleted
    }

    /// 供会话视图一次性渲染的完整状态快照。
    struct State: Equatable {
        /// 按展示顺序排列的历史提示、时间、消息与输入状态项。
        let timeline: [TimelineItem]
        /// 指示是否显示对方正在输入的布尔值。
        let isTyping: Bool
        /// 指示发送、排队回复或活动回复是否仍在处理的布尔值。
        var isProcessingMessages: Bool = false
        /// 历史加载状态；默认关闭，避免无数据源的注入入口自动加载或显示状态项。
        var historyState: HistoryLoadingState = .disabled
    }

    /// 在主 Actor 上取得当前日期的闭包类型。
    typealias Clock = @MainActor () -> Date
    /// 在主 Actor 上取得当前区域设置的闭包类型。
    typealias LocaleProvider = @MainActor () -> Locale
    /// 可取消的异步延时操作类型，用于模拟回复时序。
    typealias Sleeper = @Sendable (Duration) async throws -> Void
    /// 携带完整状态及更新原因的渲染回调类型。
    typealias StateHandler = (State, UpdateReason) -> Void

    /// 插入时间分隔项所需的相邻消息最小间隔，单位为秒。
    static let timestampInterval: TimeInterval = 5 * 60

    /// 将消息资源键解析为当前语言文字的本地化服务。
    let localizer: Localizer
    /// 生成消息时间的可注入时钟。
    let clock: Clock
    /// 在生成模拟回复时捕获当前语言的区域设置提供者。
    let localeProvider: LocaleProvider
    /// 控制模拟阅读与回复延时的可注入挂起操作。
    let sleeper: Sleeper
    /// 为音频消息生成同类型回复的可选合成器。
    let replyAudioSynthesizer: (any ReplyAudioSynthesizing)?
    /// 当前绑定的状态渲染回调。
    var render: StateHandler?
    /// 按进入会话顺序保存的原始消息数组。
    var messages: [Message]
    /// 下一条新增消息将使用的递增标识符。
    var nextMessageID: Int
    /// 防止首次历史加载重复完成时再次插入消息。
    private var hasInsertedInitialHistory = false
    /// 当前会话的可替换历史来源；未配置时不启用分页。
    var historySource: (any MessageHistoryLoading)?
    /// 唯一的活动历史请求，完成或取消后清空，用于拦截重复加载。
    var historyTask: Task<Void, Never>?
    /// 上次成功加载返回的下一页游标；是否已加载过首页由 `hasLoadedHistoryPage` 区分。
    var historyCursor: String?
    /// 历史请求的权威状态，生成快照时同步给顶部提示和滚动触发逻辑。
    var historyState: HistoryLoadingState = .disabled
    /// 来源身份到本地消息 ID 的映射；删除消息后仍保留映射以拒绝重复导入。
    var historySourceIDs: [String: Int] = [:]
    /// 当前请求的身份令牌；新请求或页面退出时更换，用于拒绝迟到结果。
    var historyGeneration = UUID()
    /// 是否成功接收过首页，用于选择请求大小、游标语义和首次展示策略。
    var hasLoadedHistoryPage = false
    /// 会话是否已退出；一旦失效，不再允许配置来源或接收历史结果。
    var historyInvalidated = false

    /// 串行处理模拟回复队列的任务；空闲时为 `nil`。
    var pendingReplyTask: Task<Void, Never>?
    /// 按发送顺序保存的待回复消息身份与回复类型。
    var pendingReplies: [(messageID: Int, kind: ReplyKind)] = []
    /// 当前是否需要在时间线显示对方输入状态。
    var isTyping = false
    /// 提供异步发送确认或失败结果的消息发送器。
    let messageSender: any MessageSending
    /// 指示是否接受并应用模拟阅读回执的布尔值。
    let readReceiptsEnabled: Bool
    /// 按消息身份索引的活动发送任务。
    var sendTasks: [Int: Task<Void, Never>] = [:]
    /// 每条消息当前发送尝试的令牌，用于拒绝旧尝试的异步结果。
    var sendAttempts: [Int: UUID] = [:]
    /// 回复队列当前代次的令牌，取消后更换以使旧结果失效。
    var replyGeneration = UUID()
    /// 当前正在生成回复的原发出消息标识符。
    var activeReplyID: Int?

    /// 最近一次生成并向界面发布的完整状态快照。
    var state: State

    /// 使用实时本地化、系统时钟和默认模拟发送器创建视图模型。
    convenience init() {
        self.init(
            localizer: .live,
            clock: Date.init,
            localeProvider: {
                Localization.localizationController.currentLocale.locale
            },
            replyAudioSynthesizer: nil,
            sleeper: { duration in
                try await Task.sleep(for: duration)
            }
        )
    }

    /// 创建使用指定模拟回复音频合成器的视图模型。
    ///
    /// - Parameter replyAudioSynthesizer: 为发出的音频消息生成同类型回复的对象。
    convenience init(
        replyAudioSynthesizer: any ReplyAudioSynthesizing
    ) {
        self.init(
            localizer: .live,
            clock: Date.init,
            localeProvider: {
                Localization.localizationController.currentLocale.locale
            },
            replyAudioSynthesizer: replyAudioSynthesizer,
            sleeper: { duration in
                try await Task.sleep(for: duration)
            }
        )
    }

    /// 使用可注入依赖创建聊天视图模型，初始消息列表为空。
    ///
    /// - Parameters:
    ///   - localizer: 用于解析资源键的本地化服务。
    ///   - clock: 新消息时间来源。
    ///   - localeProvider: 发送时捕获的语言来源，默认使用当前应用区域设置。
    ///   - replyAudioSynthesizer: 可选的音频回复合成器。
    ///   - messageSender: 可选消息发送器；省略时使用本地模拟实现。
    ///   - readReceiptsEnabled: 是否处理阅读回执，默认值为 `true`。
    ///   - sleeper: 可取消的模拟时序延时操作。
    init(
        localizer: Localizer,
        clock: @escaping Clock,
        localeProvider: @escaping LocaleProvider = {
            Localization.localizationController.currentLocale.locale
        },
        replyAudioSynthesizer: (any ReplyAudioSynthesizing)? = nil,
        messageSender: (any MessageSending)? = nil,
        readReceiptsEnabled: Bool = true,
        sleeper: @escaping Sleeper
    ) {
        self.localizer = localizer
        self.clock = clock
        self.localeProvider = localeProvider
        self.replyAudioSynthesizer = replyAudioSynthesizer
        self.sleeper = sleeper
        self.messageSender = messageSender ?? SimulatedMessageSender.liveDemo()
        self.readReceiptsEnabled = readReceiptsEnabled

        messages = []
        nextMessageID = 0
        state = State(timeline: [], isTyping: false)
        state = makeState()
    }

    /// 在视图模型释放时取消历史请求、回复工作任务和全部发送任务。
    deinit {
        historyTask?.cancel()
        pendingReplyTask?.cancel()
        sendTasks.values.forEach { $0.cancel() }
    }

    /// 在会话开头批量插入首次加载的历史，保留期间新增的消息和发送任务。
    func insertInitialHistory(_ entries: [MessageHistoryEntry]) {
        guard !hasInsertedInitialHistory else { return }
        hasInsertedInitialHistory = true
        let date = messages.first?.sentAt ?? clock()
        let history = entries.enumerated().map { offset, entry in
            Message(id: nextMessageID + offset, direction: entry.direction, content: entry.content,
                    sentAt: date.addingTimeInterval(Double(offset - entries.count)),
                    deliveryState: entry.direction == .outgoing ? .read : nil)
        }
        nextMessageID += history.count
        messages.insert(contentsOf: history, at: 0)
        publish(reason: .historyLoaded)
    }

    #if DEBUG
    /// 仅用于真实系统保存流程的 UI 回归与预览启动参数。
    /// 默认追加收到的附件；发出方向用于检查蓝色语音气泡的菜单收起画面。
    ///
    /// - Parameters:
    ///   - attachment: 已准备好的本地测试附件。
    ///   - direction: 样例消息方向，默认为 `.incoming`；仅影响样例展示，不模拟发送流程。
    func appendSavePreviewAttachment(_ attachment: Attachment, direction: MessageDirection = .incoming) {
        messages.append(.init(id: nextMessageID, direction: direction, content: .attachment(attachment),
                              sentAt: clock(), deliveryState: nil))
        nextMessageID += 1
        publish(reason: .receivedMessage)
    }
    #endif

    /// 替换状态渲染回调，并立即以初始原因交付当前状态。
    func bind(_ render: @escaping StateHandler) {
        self.render = render
        render(state, .initial)
    }

    /// 仅更新身份仍匹配的音频，不改变消息生命周期或重新安排回复。
    @discardableResult
    func updateAudioTranscript(_ rawText: String, messageID: Int, attachmentID: UUID) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              case .attachment(.audio(var audio)) = messages[index].content,
              audio.id == attachmentID, audio.transcript == nil else { return false }
        audio.transcript = text
        messages[index].content = .attachment(.audio(audio))
        publish(reason: .audioTranscript)
        return true
    }

    /// 按当前语言重新生成并发布展示状态，保留消息原始载荷。
    func refreshLocalizedContent() {
        publish(reason: .localization)
    }
}
