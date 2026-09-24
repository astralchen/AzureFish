import AppLocalization
import Testing
import UIKit
@testable import AzureFish

/// 验证历史分页的数量、去重、取消、并发消息及真实窗口中的阅读位置。
extension ChatHistoryTests {
    /// 使用真实样例资源加载全部四页，确认 98 条消息有序且导入不触发发送或回复。
    @Test func paginatedSampleContains98OrderedUniqueMessagesWithoutSending() async throws {
        guard #available(iOS 26.0, *) else { return }
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let model = ChatViewModel()
        model.configureHistory(source: SampleHistoryLoader(store: store, sleeper: { _ in }))
        for count in [38, 58, 78, 98] {
            model.loadHistory()
            #expect(await historyEventually { model.historyTask == nil })
            #expect(model.messages.count == count)
            #expect(model.messages.map(\.sentAt) == model.messages.map(\.sentAt).sorted())
            #expect(Set(model.messages.map(\.id)).count == count)
            #expect(model.sendTasks.isEmpty && model.pendingReplies.isEmpty && !model.state.isProcessingMessages)
        }
        #expect(model.historyState == .exhausted)
        #expect(model.historyCursor == nil)
        // 60 条更早样例各相隔六分钟，再加首屏消息所在分组，共产生 61 个时间分隔项。
        #expect(model.state.timeline.filter { if case .timestamp = $0.content { true } else { false } }.count == 61)
        model.loadHistory()
        #expect(model.historyTask == nil && model.messages.count == 98)
    }

    /// 验证请求互斥、失败不推进游标，以及同页和跨页重复记录不改变已有本地身份。
    @Test func duplicateRequestsFailureRetryAndOverlappingPagesKeepStableIDs() async throws {
        guard #available(iOS 26.0, *) else { return }
        let source = ControlledHistorySource()
        let model = ChatViewModel()
        model.configureHistory(source: source)
        model.loadHistory()
        for _ in 0..<5 { model.loadHistory() }
        #expect(await historyEventually { source.requests.count == 1 })
        #expect(source.requests[0].limit == 38)
        source.finish(.success(.init(messages: [source.item(20), source.item(21)], nextCursor: "older")))
        #expect(await historyEventually { model.historyState == .idle })
        let ids = model.messages.map(\.id)
        model.loadHistory()
        #expect(await historyEventually { source.requests.count == 2 })
        source.finish(.failure(URLError(.timedOut)))
        #expect(await historyEventually { model.historyState == .failed })
        #expect(model.historyCursor == "older" && model.messages.map(\.id) == ids)
        model.loadHistory()
        #expect(model.historyTask == nil)
        model.loadHistory(retrying: true)
        #expect(await historyEventually { source.requests.count == 3 })
        #expect(source.requests[1].cursor == source.requests[2].cursor)
        #expect(source.requests[2].limit == 20)
        source.finish(.success(.init(messages: [source.item(19), source.item(19), source.item(20)], nextCursor: nil)))
        #expect(await historyEventually { model.historyState == .exhausted })
        #expect(model.messages.count == 3)
        #expect(Array(model.messages.suffix(2)).map(\.id) == ids)
    }

    /// 分别验证显式取消和模型释放后，忽略取消的来源返回的页面仍被丢弃。
    @Test func cancelledAndReleasedModelsDiscardUnacceptedPages() async throws {
        guard #available(iOS 26.0, *) else { return }
        for release in [false, true] {
            let source = ControlledHistorySource()
            var model: ChatViewModel? = ChatViewModel()
            weak let weakModel = model
            model?.configureHistory(source: source)
            model?.loadHistory()
            #expect(await historyEventually { source.requests.count == 1 })
            if release { model = nil } else { model?.cancelHistory() }
            if release { #expect(weakModel == nil) }
            source.finish(.success(.init(messages: [source.item(0)], nextCursor: nil)))
            #expect(await historyEventually { source.discarded == 1 })
            #expect(model?.messages.isEmpty ?? true)
        }
    }

    /// 首次失败后仍以首页参数重试；接收到空页且没有后续游标时正常结束加载。
    @Test func initialFailureRetriesAndEmptyPageFinishes() async throws {
        guard #available(iOS 26.0, *) else { return }
        let source = ControlledHistorySource()
        let model = ChatViewModel()
        model.configureHistory(source: source)
        model.loadHistory()
        #expect(await historyEventually { source.requests.count == 1 })
        source.finish(.failure(URLError(.notConnectedToInternet)))
        #expect(await historyEventually { model.historyState == .failed })
        #expect(!model.hasLoadedHistoryPage)
        model.loadHistory(retrying: true)
        #expect(await historyEventually { source.requests.count == 2 })
        #expect(source.requests[1].cursor == nil && source.requests[1].limit == 38)
        source.finish(.success(.init(messages: [], nextCursor: nil)))
        #expect(await historyEventually { model.historyState == .exhausted })
        #expect(model.messages.isEmpty)
    }

    /// 验证请求期间的新消息被保留，而删除过的历史不会被重叠页重新导入。
    @Test func loadingKeepsNewMessagesAndDoesNotResurrectDeletedHistory() async throws {
        guard #available(iOS 26.0, *) else { return }
        let source = ControlledHistorySource()
        let model = ChatViewModel()
        defer { model.cancelPendingReply() }
        model.configureHistory(source: source)
        model.loadHistory()
        #expect(await historyEventually { source.requests.count == 1 })
        #expect(model.send("sent during history request"))
        let sentID = try #require(model.messages.last?.id)
        source.finish(.success(.init(messages: [source.item(20)], nextCursor: "older")))
        #expect(await historyEventually { model.historyState == .idle })
        let historyID = try #require(model.messages.first?.id)
        model.loadHistory()
        #expect(await historyEventually { source.requests.count == 2 })
        model.messages.removeAll { $0.id == historyID }
        model.publish(reason: .messageDeleted)
        source.finish(.success(.init(messages: [source.item(19), source.item(20)], nextCursor: nil)))
        #expect(await historyEventually { model.historyState == .exhausted })
        #expect(!model.messages.contains { $0.id == historyID })
        #expect(model.messages.contains { $0.id == sentID })
        #expect(model.messages.map(\.sentAt) == model.messages.map(\.sentAt).sorted())
    }

    /// 在真实窗口连续插入三页变高消息，验证视口变化与状态刷新交错时的位置误差小于 2 pt。
    @Test func earlierPagesKeepVisibleMessageThroughStatusAndViewportChanges() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIViewController()
        let view = ConversationView(frame: window.bounds)
        host.view = view
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let source = ControlledHistorySource()
        let model = ChatViewModel()
        model.configureHistory(source: source)
        model.bind { view.render($0, reason: $1) }
        view.loadEarlierHistory = { model.loadHistory() }
        model.loadHistory()
        #expect(await historyEventually { source.requests.count == 1 })
        source.finish(.success(.init(messages: (60..<98).map { source.item($0) }, nextCursor: "60")))
        let list = view.collectionView
        #expect(await historyEventually { list.alpha == 1 && view.isNearBottom })
        // 程序化到顶不会请求下一页。
        list.setContentOffset(.zero, animated: false)
        #expect(source.requests.count == 1)
        for page in 0..<3 {
            view.scrollViewWillBeginDragging(list)
            list.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
            list.layoutIfNeeded()
            model.loadHistory()
            #expect(await historyEventually { source.requests.count == page + 2 })
            // 请求期间改变阅读位置和键盘遮挡，结果应使用提交前的当前锚点。
            list.setContentOffset(CGPoint(x: 0, y: 700), animated: false)
            view.updateViewportInsets(UIEdgeInsets(top: 20, left: 0, bottom: 250, right: 0))
            list.layoutIfNeeded()
            let index = try #require(list.indexPathsForVisibleItems.sorted().first { index in
                guard case .message = model.state.timeline[index.item].content,
                      let frame = list.layoutAttributesForItem(at: index)?.frame else { return false }
                return frame.intersects(list.bounds.inset(by: list.adjustedContentInset))
            })
            let id = model.state.timeline[index.item].id
            let y = try #require(list.layoutAttributesForItem(at: index)).frame.minY - list.contentOffset.y
            let end = 60 - page * 20
            source.finish(.success(.init(messages: ((end - 20)..<end).map { source.item($0) }, nextCursor: page == 2 ? nil : String(end - 20))))
            #expect(await historyEventually { model.historyTask == nil })
            // 紧接分页提交的状态刷新不能丢掉尚未完成的阅读锚点。
            model.publish(reason: .messageStatus)
            var actualY: CGFloat?
            #expect(await historyEventually {
                list.layoutIfNeeded()
                guard let item = model.state.timeline.firstIndex(where: { $0.id == id }),
                      let frame = list.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame else { return false }
                actualY = frame.minY - list.contentOffset.y
                return abs(actualY! - y) < 2
            }, "page \(page), expected y \(y), actual y \(String(describing: actualY))")
        }
        #expect(model.messages.count == 98)
        #expect(source.requests.count == 4)
    }

    /// 最多等待约五秒，让主 Actor 的加载任务和列表布局有机会完成。
    ///
    /// - Parameter predicate: 需轮询的状态判断；布局测试可在其中推进布局以读取几何。
    /// - Returns: 条件是否在等待期间或最后一次检查时成立。
    private func historyEventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return predicate()
    }
}

/// 故意忽略 Task 取消，用来验证模型拒绝迟到结果而非仅依赖来源遵守取消。
@MainActor
private final class ControlledHistorySource: MessageHistoryLoading {
    /// 按调用顺序记录游标与页大小，用于检查重复请求和失败重试参数。
    var requests: [(cursor: String?, limit: Int)] = []
    /// 模型要求丢弃的结果次数，用于确认迟到页未被接收。
    var discarded = 0
    /// 当前请求的挂起续体，由测试明确指定成功或失败的完成时机。
    private var pending: CheckedContinuation<HistoryPage, Error>?
    /// 记录请求后挂起，故意不自动响应取消，以覆盖来源不遵守取消的情况。
    func loadPage(before cursor: String?, limit: Int) async throws -> HistoryPage {
        requests.append((cursor, limit))
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    /// 先移除活动续体再交付结果，避免重复完成或恢复后的重入影响下一次请求。
    ///
    /// - Parameter result: 测试期望当前请求收到的页面或错误。
    func finish(_ result: Result<HistoryPage, Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
    /// 记录丢弃行为；此测试来源仅生成文字，不持有需要清理的文件。
    func discard(_ page: HistoryPage) { discarded += 1 }
    /// 生成身份、时间与可变行数均由索引决定的消息，供跨页重叠与自适应高度测试复用。
    ///
    /// - Parameter index: 稳定样例编号；时间按每条 30 秒递增，行数按四条循环变化。
    /// - Returns: 不依赖实时系统时钟的文字历史消息。
    func item(_ index: Int) -> HistoryMessage {
        HistoryMessage(sourceID: String(index), sentAt: Date(timeIntervalSince1970: Double(index) * 30),
            direction: index.isMultiple(of: 2) ? .incoming : .outgoing,
            content: .userText("Message \(index)" + String(repeating: "\nVariable-height history", count: index % 4)))
    }
}
