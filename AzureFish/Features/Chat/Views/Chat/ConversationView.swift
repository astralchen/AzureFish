//
//  ConversationView.swift
//  Demo
//

import AppLocalization
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 用户在时间线消息上发起的操作。
///
/// 图片、视频和音频操作均由 ViewController 路由到对应协调器；Conversation View
/// 和 Cell 不直接创建页面级播放器。
nonisolated enum MessageAction: Equatable, Sendable {
    /// 请求重试指定身份的失败消息。
    case retryMessage(messageID: Int)
    /// 执行菜单打开时锁定的内容操作。
    case menu(MessageMenuOperation, MessageMenuTarget)
    /// 请求打开文件或链接附件。
    case openDocument(messageID: Int, attachment: Attachment)
    /// 请求保存指定消息中的附件。
    case saveAttachment(messageID: Int, attachment: Attachment)
    /// 请求切换指定消息音频的播放状态。
    case toggleAudioPlayback(
        messageID: Int,
        attachment: AudioAttachment
    )
    /// 请求从指定索引打开媒体组的全屏预览。
    case openMediaGroup(
        messageID: Int,
        attachment: MediaGroupAttachment,
        index: Int
    )
}

/// 将时间线状态映射为可复用消息单元格，并管理滚动与局部交互的视图。
@available(iOS 17.0, *)
final class ConversationView: QuickLayoutView, UICollectionViewDelegate, UIGestureRecognizerDelegate {

    /// 会话集合视图使用的稳定分区身份。
    nonisolated enum Section: Hashable, Sendable {
        /// 包含所有时间分隔、消息和输入状态项的时间线分区。
        case timeline
    }

    /// 垂直滚动并支持交互式收起键盘的消息集合视图。
    let collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: UICollectionViewFlowLayout()
    )

    /// 首次展示与后续消息滚动分开管理；隐藏期间集合视图仍参与真实布局。
    private(set) lazy var initialPresentation = ConversationInitialPresentation(collectionView: collectionView)
    /// 子视图首次挂载可能晚于控制器布局回调，展示前必须先同步最终边距。
    var viewportDidLayout: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        initialPresentation.resumeIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        viewportDidLayout?()
        // QuickLayout 可能在容器进入窗口之后才挂载集合视图，空快照尤其容易先完成。
        initialPresentation.resumeIfNeeded()
    }

    /// 让消息列表随会话容器填满可用空间。
    override var body: Layout {
        collectionView.resizable()
    }

    /// 将时间线模型映射到单元格并执行差异更新的 ListKit 适配器。
    private lazy var adapter = CollectionListAdapter<Section>(
        collectionView: collectionView
    )
    /// 当前渲染版本，用于使旧列表完成回调失效。
    private var renderGeneration = 0
    /// 初始加载或发送触发的底部滚动请求；跨越状态刷新保留至滚动完成。
    private var pendingExplicitScroll = false
    /// 首次历史等待期间发生过拖动或发送时，批量插入应保留阅读位置。
    private var hasInteractedWithTimeline = false
    /// 用户向顶部翻看且满足阈值时请求下一页，由页面转交模型处理。
    var loadEarlierHistory: (() -> Void)?
    /// 用户点击顶部失败提示时请求重试，区别于自动滚动触发。
    var retryHistory: (() -> Void)?
    /// 标记当前一次拖动及其减速过程是否已请求过历史，防止短列表连续自动翻页。
    private var requestedHistoryDuringDrag = false
    /// 上次滚动回调的纵向偏移，用于判断本次是否向更早记录移动。
    private var previousScrollOffset: CGFloat = 0
    /// 标记快照应用及位置恢复过程，避免程序化滚动触发新的历史请求。
    private var isApplyingTimeline = false
    /// 用户继续滚动或视口改变后，旧快照的完成回调不能恢复过时位置。
    private var readingPositionRevision = 0
    /// 分页插入前的可见消息身份及屏幕偏移，跨连续状态刷新保留至最新快照完成。
    private var pendingHistoryAnchor: (id: TimelineItemID, anchor: UICollectionViewLocalizationAnchor)?

    /// 只选择实际未被导航栏和输入栏遮挡的消息，时间分隔项可随跨页合并而消失。
    ///
    /// - Parameter state: 与当前列表位置对应的插入前状态，用于将索引转换为稳定消息身份。
    /// - Returns: 首条可见消息的身份及距视口顶部、语义前缘的偏移；无可见消息时为 `nil`。
    private func captureMessageAnchor(in state: ChatViewModel.State?) -> (id: TimelineItemID, anchor: UICollectionViewLocalizationAnchor)? {
        guard let state else { return nil }
        let list = collectionView
        list.layoutIfNeeded()
        let viewport = list.bounds.inset(by: viewportInsets)
        for index in list.indexPathsForVisibleItems.sorted() {
            guard state.timeline.indices.contains(index.item),
                  case .message = state.timeline[index.item].content,
                  let frame = list.layoutAttributesForItem(at: index)?.frame,
                  frame.intersects(viewport) else { continue }
            return (state.timeline[index.item].id, .init(indexPath: index,
                offsetFromViewportTop: frame.minY - viewport.minY,
                offsetFromViewportLeading: list.effectiveUserInterfaceLayoutDirection == .rightToLeft
                    ? viewport.maxX - frame.maxX : frame.minX - viewport.minX))
        }
        return nil
    }
    /// 按消息和附件组合身份查询权威保存状态的回调。
    var attachmentSaveState: ((AttachmentSaveKey) -> AttachmentSaveState)?
    /// 最近一次渲染的完整状态，用于附件保存状态变化时重新配置列表。
    private var lastState: ChatViewModel.State?
    private struct ViewportPosition {
        let followsBottom: Bool
        let itemID: TimelineItemID?
        let anchor: UICollectionViewLocalizationAnchor?
    }
    private var pendingViewportPosition: ViewportPosition?
    private var viewportSize: CGSize = .zero
    /// 实际可见区域的物理边距；左右边距交给 Section 布局，不扩大滚动内容范围。
    private var viewportInsets: UIEdgeInsets = .zero
    private var isUpdatingViewport = false

    #if DEBUG
    private var debugScrollSequence = 0
    private var debugScrollGesture = 0
    #endif

    /// 显式开启聊天诊断后只读取现有几何，不调用布局或锚点捕获，避免日志改变时序。
    /// 不输出消息正文、附件地址或草稿内容。Release 不生成诊断输出。
    func debugLogScroll(_ event: String, detail: @autoclosure () -> String = "") {
        #if DEBUG
        guard ChatDiagnostics.isEnabled else { return }
        debugScrollSequence &+= 1
        let list = collectionView
        let pan = list.panGestureRecognizer
        let minimum = -list.adjustedContentInset.top
        let maximum = max(minimum, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
        let cell = list.visibleCells.min { $0.frame.minY < $1.frame.minY }
        let visible = cell.map { cell in
            let index = list.indexPath(for: cell)
            let id = index.flatMap { index in
                lastState?.timeline.indices.contains(index.item) == true ? lastState?.timeline[index.item].id : nil
            }
            return "id=\(String(describing: id)) frame=\(cell.frame) screenY=\(cell.frame.minY - list.contentOffset.y)"
        } ?? "none"
        ChatDiagnostics.log("[ChatScroll] t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime)) view=\(ObjectIdentifier(self)) n=\(debugScrollSequence) gesture=\(debugScrollGesture) event=\(event) "
            + "offset=\(list.contentOffset) size=\(list.contentSize) bounds=\(list.bounds.size) rangeY=\(minimum)...\(maximum) "
            + "inset=\(list.contentInset) adjusted=\(list.adjustedContentInset) safe=\(list.safeAreaInsets) viewport=\(viewportInsets) "
            + "tracking=\(list.isTracking) dragging=\(list.isDragging) decelerating=\(list.isDecelerating) pan=\(pan.state.rawValue) translation=\(pan.translation(in: list)) "
            + "presented=\(initialPresentation.isPresented) applying=\(isApplyingTimeline) updatingViewport=\(isUpdatingViewport) explicitBottom=\(pendingExplicitScroll) pendingFollow=\(String(describing: pendingViewportPosition?.followsBottom)) revision=\(readingPositionRevision) "
            + "visible={\(visible)} \(detail())")
        #endif
    }

    /// 在改变输入栏高度或容器尺寸前捕获阅读位置；身份独立于历史插入后的索引。
    func prepareForViewportChange() {
        guard pendingViewportPosition == nil, !isUpdatingViewport else { return }
        debugLogScroll("viewport.capture.begin")
        let anchor = collectionView.captureLocalizationAnchor()
        let itemID = anchor.flatMap { anchor in
            lastState?.timeline.indices.contains(anchor.indexPath.item) == true
                ? lastState?.timeline[anchor.indexPath.item].id : nil
        }
        pendingViewportPosition = ViewportPosition(
            followsBottom: pendingExplicitScroll || isNearBottom, itemID: itemID, anchor: anchor
        )
        debugLogScroll("viewport.capture.end", detail: "anchor=\(String(describing: anchor))")
    }

    /// 列表 frame 始终全屏，只有内容及指示器避让覆盖在其上方的界面。
    func updateViewportInsets(_ insets: UIEdgeInsets) {
        guard !isUpdatingViewport else { return }
        let old = viewportInsets
        let horizontalGeometryChanged = abs(old.left - insets.left) > 0.5
            || abs(old.right - insets.right) > 0.5
            || abs(viewportSize.width - collectionView.bounds.width) > 0.5
        let requiresPositionRestoration = horizontalGeometryChanged
            || abs(old.bottom - insets.bottom) > 0.5
            || abs(viewportSize.height - collectionView.bounds.height) > 0.5
        guard abs(old.top - insets.top) > 0.5 || requiresPositionRestoration else {
            if pendingViewportPosition != nil { debugLogScroll("viewport.unchanged.discardPending") }
            pendingViewportPosition = nil
            return
        }
        debugLogScroll("viewport.begin", detail: "old=\(old) new=\(insets) oldSize=\(viewportSize)")
        // 导航栏随滚动展开/收起时只改变顶部遮挡。此时恢复锚点或贴底会反向改写
        // contentOffset，再次驱动导航栏和安全区变化，形成与手势争抢位置的循环。
        // 即使手势已结束也不补偿顶部变化，避免导航栏的后续动画继续触发循环。
        if requiresPositionRestoration { prepareForViewportChange() }
        readingPositionRevision &+= 1
        let position = pendingViewportPosition
        pendingViewportPosition = nil
        isUpdatingViewport = true
        defer {
            // 只保留纵向阅读位置，清除尺寸或安全区切换前遗留的横向偏移。
            if collectionView.contentOffset.x != 0 { collectionView.contentOffset.x = 0 }
            isUpdatingViewport = false
            debugLogScroll("viewport.end")
        }
        viewportSize = collectionView.bounds.size
        viewportInsets = insets
        collectionView.contentInset = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        collectionView.scrollIndicatorInsets = insets
        if horizontalGeometryChanged {
            debugLogScroll("viewport.invalidateLayout")
            collectionView.collectionViewLayout.invalidateLayout()
        }
        collectionView.layoutIfNeeded()
        // 首次展示协调器负责最终底部定位，不能提前显示尚未稳定的历史。
        guard initialPresentation.isPresented else { return }
        guard requiresPositionRestoration else {
            debugLogScroll("viewport.topInsetOnly")
            return
        }
        if position?.followsBottom == true {
            debugLogScroll("viewport.followBottom")
            scrollToBottom(animated: false)
        } else if let id = position?.itemID, let anchor = position?.anchor,
                  let item = lastState?.timeline.firstIndex(where: { $0.id == id }) {
            let restored = UICollectionViewLocalizationAnchor(
                indexPath: IndexPath(item: item, section: 0),
                offsetFromViewportTop: anchor.offsetFromViewportTop,
                offsetFromViewportLeading: anchor.offsetFromViewportLeading
            )
            debugLogScroll("viewport.restore.begin", detail: "itemID=\(id) anchor=\(restored)")
            collectionView.restoreLocalizationAnchor(restored)
            collectionView.layoutIfNeeded()
            collectionView.restoreLocalizationAnchor(restored)
            debugLogScroll("viewport.restore.end")
        }
    }

    /// 全屏列表中的 cell 可能仍处于导航栏或输入栏后方，预览转场只使用完整可见来源。
    func isUnobscuredPreviewSource(_ source: UIView) -> Bool {
        guard source.window != nil, source.isDescendant(of: collectionView) else { return false }
        let viewport = collectionView.bounds.inset(by: viewportInsets)
        let frame = source.convert(source.bounds, to: collectionView)
        return !frame.isEmpty && viewport.contains(frame)
    }
    /// 收到保存状态通知后记录的附件状态缓存。
    private var saveStates: [AttachmentSaveKey: AttachmentSaveState] = [:]

    /// 更新指定附件的保存状态，并以保存原因重新渲染当前时间线。
    func updateSaveState(_ state: AttachmentSaveState, for key: AttachmentSaveKey) {
        saveStates[key] = state
        if let lastState { render(lastState, reason: .attachmentSave) }
    }

    /// 返回指定消息的附件保存状态，优先使用页面状态提供者。
    private func saveState(for message: MessagePresentation) -> AttachmentSaveState {
        guard case .attachment(let attachment) = message.content else { return .hidden }
        let key = AttachmentSaveKey(messageID: message.id, attachmentID: attachment.id)
        return attachmentSaveState?(key) ?? saveStates[key] ?? .available
    }

    /// 将消息内容身份与保存反馈组合的单元格刷新身份。
    nonisolated private struct SaveRefreshIdentity: Hashable, Sendable {
        /// 消息正文、附件、方向与发送状态构成的内容身份。
        let message: MessageRefreshIdentity
        /// 当前附件保存状态，参与判断单元格是否需要重新配置。
        let state: AttachmentSaveState
    }

    /// 将消息内容身份和当前保存状态组合为列表刷新标识。
    private func saveRefreshIdentity(_ message: MessagePresentation) -> SaveRefreshIdentity {
        .init(message: message.refreshIdentity, state: saveState(for: message))
    }

    /// 最近一次提交的时间线项目数量，用于判断初始滚动行为。
    private var timelineCount = 0
    /// 最近一次显式应用的界面布局方向。
    private var lastAppliedLayoutDirection: UIUserInterfaceLayoutDirection?
    /// 页面音频控制器发布的播放状态，供可见和新配置单元格共用。
    private var playbackState: PlaybackState = .idle
    /// 按消息身份保留媒体组当前封面索引的状态存储。
    private let mediaStackStateStore = MediaStackStateStore()
    /// 媒体消息和预览入口配置时使用的本地化文字集合。
    private var mediaStrings = MediaStrings(
        photo: "Photos",
        itemsFormat: "%d items",
        image: "Image",
        animatedImage: "Animated image",
        video: "Video",
        videoDurationFormat: "Video, duration %@",
        importing: "Importing",
        remove: "Remove",
        play: "Play",
        openPreview: "Open preview",
        close: "Close",
        firstItem: "First item",
        lastItem: "Last item",
        positionFormat: "%d of %d"
    )

    /// 消息 Cell 请求页面级操作时调用。
    var actionRequested: ((MessageAction) -> Void)?
    /// 辅助功能请求完整查看附件时调用；目标包含媒体组当前项的稳定标识。
    var openMenuAttachment: ((MessageMenuTarget) -> Void)?
    /// 列表级菜单协调对象，统一持有会话、来源解析与关闭后的操作交付。
    private lazy var messageMenuCoordinator = MessageMenuCoordinator(collectionView: collectionView,
        resolve: { [weak self] in self?.menuSource(for: $0) },
        items: { [weak self] in self?.menuItems(for: $0) ?? [] },
        perform: { [weak self] in self?.actionRequested?(.menu($0, $1)) })
    /// 查询菜单目标的实时保存状态；未提供时按可保存状态生成菜单。
    var menuSaveState: ((MessageMenuTarget) -> AttachmentSaveState)?

    /// 重新查询可见 Cell；收回媒体组前同步封面而不移动列表。
    func previewSource(messageID: Int, attachmentID: UUID, index: Int, synchronize: Bool) -> UIView? {
        guard let message = lastState?.timeline.compactMap({ item -> MessagePresentation? in
            guard case .message(let message) = item.content else { return nil }; return message
        }).first(where: { $0.id == messageID }), case .attachment(let attachment) = message.content,
              attachment.id == attachmentID else { return nil }
        if case .mediaGroup(let group) = attachment {
            if synchronize { mediaStackStateStore.setIndex(index, for: messageID, itemCount: group.items.count) }
            guard let cell = collectionView.visibleCells.compactMap({ $0 as? MediaBubbleCell }).first(where: { $0.previewMessageID == messageID }) else { return nil }
            if synchronize {
                cell.mediaView.configure(messageID: messageID, direction: message.direction, group: group, frontIndex: index, strings: mediaStrings)
                cell.layoutIfNeeded()
                cell.mediaView.layoutIfNeeded()
            }
            guard let source = cell.mediaView.previewSourceView else { return nil }
            return isUnobscuredPreviewSource(source) ? source : nil
        }
        guard let source = collectionView.visibleCells.compactMap({ $0 as? DocumentBubbleCell })
            .first(where: { $0.previewMessageID == messageID })?.card else { return nil }
        return isUnobscuredPreviewSource(source) ? source : nil
    }

    /// 使用指定初始边框创建 `ConversationView`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        configureCollectionView()
        _ = initialPresentation
        adapter.collectionDelegate = self
        // UIKit 在安装 delegate 时缓存可选 selector。转发目标就绪后重新安装，
        // 否则 willEndContextMenuInteraction 不会送达，菜单动作一直留在队列中。
        collectionView.delegate = nil
        collectionView.delegate = adapter
        // 只接受单个消息内容来源；任意可见文字处于选择状态时，不再创建消息菜单。
        adapter.contextMenuForItems { [weak self] contexts, point in
            guard let self, contexts.count == 1,
                  !collectionView.visibleCells.compactMap({ $0 as? TextBubbleCell }).contains(where: { $0.bubbleView.messageTextView.isSelectingMessageText }),
                  let indexPath = contexts.first?.indexPath,
                  let cell = collectionView.cellForItem(at: indexPath),
                  let source = menuBinding(for: cell)?.source,
                  message(for: source.target) != nil else { return nil }
            return messageMenuCoordinator.configuration(source: source, point: point)
        }
        let selectionDismiss = UITapGestureRecognizer(target: self, action: #selector(dismissSelectionOutside(_:)))
        selectionDismiss.cancelsTouchesInView = false
        selectionDismiss.delegate = self
        addGestureRecognizer(selectionDismiss)
    }

    /// 不支持从归档创建 `ConversationView`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 列表重新显示已有 Cell 时恢复缩略图消费者。
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        MediaImageView.setContentActive(true, in: cell)
        // 加载状态采用局部更新；离屏后重新出现的提示必须读取最新状态，而非旧快照文案。
        if let cell = cell as? HistoryStatusCell,
           let item = lastState?.timeline.first, case .historyStatus(let presentation) = item.content {
            cell.configure(presentation)
        }
        if let timeline = lastState?.timeline, timeline.indices.contains(indexPath.item),
           case .message(let message) = timeline[indexPath.item].content {
            configureMessageMenu(cell, message: message)
        }
    }

    /// 离屏立即取消读取并释放图像，无需等待 Cell 进入复用池。
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        MediaImageView.setContentActive(false, in: cell)
    }

    /// 开始新的用户滚动手势，重置本次分页额度，并使旧的阅读位置恢复请求失效。
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        #if DEBUG
        debugScrollGesture &+= 1
        #endif
        debugLogScroll("drag.begin")
        readingPositionRevision &+= 1
        requestedHistoryDuringDrag = false
        previousScrollOffset = scrollView.contentOffset.y
        pendingHistoryAnchor = nil
        endMessageSelection()
        hasInteractedWithTimeline = true
        pendingExplicitScroll = false
    }

    /// 在用户向顶部拖动或减速、且距内容顶部不超过 120 pt 时尝试加载更早历史。
    ///
    /// 首次展示、布局更新和程序化定位不会触发请求；失败与结束状态也不会自动重试。
    /// - Parameter scrollView: 列表适配器转发滚动事件的消息集合视图。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        debugLogScroll("scroll", detail: "deltaY=\(scrollView.contentOffset.y - previousScrollOffset)")
        defer { previousScrollOffset = scrollView.contentOffset.y }
        if !isApplyingTimeline, !isUpdatingViewport {
            readingPositionRevision &+= 1
            pendingHistoryAnchor = nil
        }
        guard scrollView === collectionView, initialPresentation.isPresented,
              !isApplyingTimeline, !isUpdatingViewport, !pendingExplicitScroll,
              scrollView.isDragging || scrollView.isDecelerating,
              scrollView.contentOffset.y < previousScrollOffset,
              scrollView.contentOffset.y + scrollView.adjustedContentInset.top <= 120,
              !requestedHistoryDuringDrag, lastState?.historyState == .idle else { return }
        requestedHistoryDuringDrag = true
        debugLogScroll("history.request")
        loadEarlierHistory?()
    }

    #if DEBUG
    /// 诊断手势与减速边界，不参与滚动位置决策。
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        debugLogScroll("drag.willEnd", detail: "velocity=\(velocity) target=\(targetContentOffset.pointee)")
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        debugLogScroll("drag.end", detail: "willDecelerate=\(decelerate)")
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        debugLogScroll("deceleration.end")
    }
    #endif

    /// 自适应高度可能在动画期间变化，完成后再对齐一次最终底部。
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        debugLogScroll("scrollAnimation.end")
        guard pendingExplicitScroll else { return }
        scrollToBottom(animated: false)
    }

    /// 将完整时间线状态串行应用到列表，并按更新原因选择滚动与阅读锚点策略。
    ///
    /// 列表完成回调只应用最新渲染版本；局部状态更新不会丢弃尚未执行的主动滚动请求。
    func render(
        _ state: ChatViewModel.State,
        reason: ChatViewModel.UpdateReason
    ) {
        debugLogScroll("render.begin", detail: "reason=\(reason) count=\(state.timeline.count)")
        if reason == .historyStatus, let previous = lastState,
           previous.timeline.map(\.id) == state.timeline.map(\.id),
           let item = state.timeline.first, case .historyStatus(let presentation) = item.content {
            // 加载状态不改变消息结构。避免为一个提示重新提交整个列表，导致
            // 排队的自适应布局在用户继续拖动之后恢复请求开始时的阅读位置。
            lastState = state
            for cell in collectionView.visibleCells.compactMap({ $0 as? HistoryStatusCell }) {
                cell.configure(presentation)
            }
            if state.historyState == .failed { initialPresentation.finishWaitingForHistory() }
            return
        }
        isApplyingTimeline = true
        defer { isApplyingTimeline = false }
        let previousState = lastState
        if reason == .sentMessage { pendingHistoryAnchor = nil }
        // 结果提交时才捕获阅读位置，避免使用请求开始后已被用户滚动改变的旧位置。
        if reason == .olderHistoryLoaded {
            pendingHistoryAnchor = captureMessageAnchor(in: previousState)
        }
        if reason == .messageDeleted { pendingExplicitScroll = false }
        lastState = state
        messageMenuCoordinator.refresh()
        if reason == .sentMessage { hasInteractedWithTimeline = true }
        let preservesHistoryPosition = reason == .olderHistoryLoaded || (reason == .historyLoaded && hasInteractedWithTimeline)
        if reason == .initial || reason == .sentMessage { pendingExplicitScroll = true }
        if reason == .historyLoaded && !preservesHistoryPosition { pendingExplicitScroll = true }
        let wasNearBottom = timelineCount == 0 || pendingExplicitScroll || isNearBottom
        // 回复落地后还会立即刷新“正在输入”状态；跟随意图必须保留到最新一次提交完成。
        if reason == .receivedMessage && wasNearBottom { pendingExplicitScroll = true }
        var localizationAnchor = (preservesHistoryPosition || reason == .historyStatus || reason == .attachmentSave || reason == .messageDeleted || ((reason == .localization || reason == .audioTranscript || reason == .messageStatus || reason == .receivedMessage) && !wasNearBottom))
            ? collectionView.captureLocalizationAnchor()
            : nil
        // 历史插入会改变 IndexPath，必须先用旧时间线身份定位同一条消息。
        if preservesHistoryPosition || reason == .messageDeleted, let anchor = localizationAnchor {
            if let previousState, previousState.timeline.indices.contains(anchor.indexPath.item),
               let item = state.timeline.firstIndex(where: {
                   $0.id == previousState.timeline[anchor.indexPath.item].id
               }) {
                localizationAnchor = .init(indexPath: IndexPath(item: item, section: 0),
                    offsetFromViewportTop: anchor.offsetFromViewportTop,
                    offsetFromViewportLeading: anchor.offsetFromViewportLeading)
            } else if reason == .messageDeleted, let previousState {
                let survivors = previousState.timeline.enumerated().filter { old in state.timeline.contains { $0.id == old.element.id } }
                if let nearest = survivors.min(by: { abs($0.offset - anchor.indexPath.item) < abs($1.offset - anchor.indexPath.item) }),
                   let newIndex = state.timeline.firstIndex(where: { $0.id == nearest.element.id }),
                   let attributes = collectionView.layoutAttributesForItem(at: IndexPath(item: nearest.offset, section: 0)) {
                    localizationAnchor = .init(indexPath: IndexPath(item: newIndex, section: 0),
                        offsetFromViewportTop: attributes.frame.minY - collectionView.contentOffset.y - collectionView.adjustedContentInset.top,
                        offsetFromViewportLeading: anchor.offsetFromViewportLeading)
                } else { localizationAnchor = nil }
            } else { localizationAnchor = nil }
        }
        // 送达等刷新可能紧接分页提交，继续使用同一消息身份，直到最新快照完成定位。
        if let saved = pendingHistoryAnchor,
           let index = state.timeline.firstIndex(where: { $0.id == saved.id }) {
            localizationAnchor = .init(indexPath: IndexPath(item: index, section: 0),
                offsetFromViewportTop: saved.anchor.offsetFromViewportTop,
                offsetFromViewportLeading: saved.anchor.offsetFromViewportLeading)
        }
        let restoresHistoryAnchor = pendingHistoryAnchor != nil || preservesHistoryPosition
        let positionRevision = readingPositionRevision
        timelineCount = state.timeline.count
        let mediaMessageIDs = Set(state.timeline.compactMap { item -> Int? in
            guard case .message(let message) = item.content,
                  message.mediaGroup != nil else { return nil }
            return message.id
        })
        mediaStackStateStore.retainMessages(mediaMessageIDs)
        renderGeneration &+= 1
        let generation = renderGeneration
        initialPresentation.willApplySnapshot()
        if reason == .historyLoaded || reason == .sentMessage || state.historyState == .failed {
            initialPresentation.finishWaitingForHistory()
        }
        // 送达、已读和键入可连续发生。必须完成前一份可见内容刷新，避免
        // coalesceLatest 取代结构提交后丢失旧 Cell 的状态变更。
        let insertsText: Bool
        if reason == .receivedMessage || reason == .sentMessage, let last = state.timeline.last,
           case .message(let message) = last.content {
            switch message.content {
            case .text, .richText: insertsText = true
            case .attachment: insertsText = false
            }
        } else { insertsText = false }
        let animatesReceivedMessage = reason == .receivedMessage && !insertsText
        let transaction = ListTransaction(
            // 收发文本立即完成插入与底部定位，避免长文本等待动画或下一次状态刷新才显示。
            animation: animatesReceivedMessage ? .automatic : .disabled,
            updatePolicy: .serial
        )

        adapter.apply(
            transaction: transaction,
            completion: { [weak self] _ in
                guard let self, self.renderGeneration == generation else {
                    return
                }
                self.debugLogScroll("render.complete", detail: "reason=\(reason) generation=\(generation)")
                self.isApplyingTimeline = true
                defer {
                    self.isApplyingTimeline = false
                    self.debugLogScroll("render.end", detail: "reason=\(reason)")
                }
                self.collectionView.layoutIfNeeded()
                self.refreshMaterializedContentLayoutDirection()

                if !self.initialPresentation.isPresented {
                    self.pendingExplicitScroll = false
                    self.initialPresentation.didApplySnapshot()
                    return
                }

                self.pendingHistoryAnchor = nil
                let explicitScroll = self.pendingExplicitScroll
                self.pendingExplicitScroll = false
                if let localizationAnchor, !explicitScroll {
                    guard self.readingPositionRevision == positionRevision else { return }
                    self.debugLogScroll("render.restore", detail: "reason=\(reason) anchor=\(localizationAnchor)")
                    _ = self.collectionView.restoreLocalizationAnchor(localizationAnchor)
                    if reason == .messageDeleted || restoresHistoryAnchor || reason == .historyStatus {
                        // 首次恢复可能使估算高度的相邻 Cell 进入视口并触发自适应测量。
                        // 完成这一轮布局后，用同一阅读锚点校正最终几何。
                        self.collectionView.layoutIfNeeded()
                        _ = self.collectionView.restoreLocalizationAnchor(localizationAnchor)
                    }
                    return
                }

                let shouldScroll: Bool = switch reason {
                case .attachmentSave, .messageDeleted, .olderHistoryLoaded, .historyStatus:
                    false
                case .historyLoaded:
                    !preservesHistoryPosition
                case .initial, .sentMessage:
                    true
                case .receivedMessage, .localization, .audioTranscript, .messageStatus:
                    wasNearBottom
                }
                guard explicitScroll || shouldScroll else { return }
                self.scrollToBottom(
                    animated: animatesReceivedMessage
                )
            }
        ) {
            ListSection(.timeline) {
                ForEach(state.timeline, id: \.id) { item in
                    switch item.content {
                    case .historyStatus(let presentation):
                        Row(model: presentation, cell: HistoryStatusCell.self) { [weak self] cell, presentation, _ in
                            cell.retry = { [weak self] in self?.retryHistory?() }
                            cell.configure(presentation)
                        }
                        .refreshID(presentation)
                        .refresh(when: .automatic, action: .reconfigure(layout: .invalidate))

                    case .timestamp(let timestamp):
                        Row(
                            model: timestamp,
                            cell: TimestampCell.self
                        ) { cell, timestamp, _ in
                            cell.configure(timestamp)
                        }
                        .refreshID(timestamp.text)

                    case .message(let message):
                        switch message.content {
                        case .text, .richText:
                            Row(
                                model: message,
                                cell: TextBubbleCell.self
                            ) { [weak self] cell, message, _ in
                                cell.deliveryStatusView.retryRequested = { [weak self] in self?.actionRequested?(.retryMessage(messageID: $0)) }
                                cell.configure(message)
                                self?.configureMessageMenu(cell, message: message)
                            }
                            .contextMenuPreview(highlighting: { [weak self] _ in
                                self?.messageMenuCoordinator.preview(for: message.id)
                            }, dismissal: { [weak self] _ in
                                self?.messageMenuCoordinator.preview(for: message.id, dismissing: true)
                            })
                            .refreshID(message.refreshIdentity)
                            .refresh(when: .automatic, action: .reconfigure(layout: .invalidate))

                        case .attachment(let attachment):
                            switch attachment {
                            case .file, .link:
                                Row(model: message, cell: DocumentBubbleCell.self) { [weak self] cell, message, _ in
                                    cell.deliveryStatusView.retryRequested = { [weak self] in self?.actionRequested?(.retryMessage(messageID: $0)) }
                                    cell.open = { [weak self] in self?.actionRequested?(.openDocument(messageID: message.id, attachment: $0)) }
                                    cell.saveRequested = { [weak self] in
                                        self?.actionRequested?(.saveAttachment(messageID: message.id, attachment: attachment))
                                    }
                                    cell.configure(message, saveState: self?.saveState(for: message) ?? .available)
                                    self?.configureMessageMenu(cell, message: message)
                                }
                                .contextMenuPreview(highlighting: { [weak self] _ in
                                    self?.messageMenuCoordinator.preview(for: message.id)
                                }, dismissal: { [weak self] _ in
                                    self?.messageMenuCoordinator.preview(for: message.id, dismissing: true)
                                })
                                .refreshID(saveRefreshIdentity(message))
                                .refresh(when: .automatic, action: .reconfigure(layout: .invalidate))
                            case .audio:
                                Row(
                                    model: message,
                                    cell: AudioBubbleCell.self
                                ) { [weak self] cell, message, _ in
                                    guard let self else { return }
                                    cell.deliveryStatusView.retryRequested = { [weak self] in self?.actionRequested?(.retryMessage(messageID: $0)) }
                                    cell.playbackRequested = {
                                        [weak self] id, audio in
                                        self?.actionRequested?(
                                            .toggleAudioPlayback(
                                                messageID: id,
                                                attachment: audio
                                            )
                                        )
                                    }
                                    cell.configure(
                                        message,
                                        playback: playbackState,
                                        playAccessibilityLabel: Localization.text(
                                            "imessage.audio.play"
                                        ),
                                        pauseAccessibilityLabel: Localization.text(
                                            "imessage.audio.pause"
                                        )
                                    )
                                    configureMessageMenu(cell, message: message)
                                }
                                .contextMenuPreview(highlighting: { [weak self] _ in
                                    self?.messageMenuCoordinator.preview(for: message.id)
                                }, dismissal: { [weak self] _ in
                                    self?.messageMenuCoordinator.preview(for: message.id, dismissing: true)
                                })
                                .refreshID(message.refreshIdentity)
                                .refresh(when: .automatic, action: .reconfigure(layout: .invalidate))
                            case .mediaGroup(let group):
                                Row(
                                    model: message,
                                    cell: MediaBubbleCell.self
                                ) { [weak self] cell, message, _ in
                                    guard let self else { return }
                                    cell.deliveryStatusView.retryRequested = { [weak self] in self?.actionRequested?(.retryMessage(messageID: $0)) }
                                    cell.frontIndexDidChange = {
                                        [weak self] messageID, index in
                                        self?.mediaStackStateStore.setIndex(
                                            index,
                                            for: messageID,
                                            itemCount: group.items.count
                                        )
                                    }
                                    cell.previewRequested = {
                                        [weak self] messageID, attachment, index in
                                        self?.actionRequested?(
                                            .openMediaGroup(
                                                messageID: messageID,
                                                attachment: attachment,
                                                index: index
                                            )
                                        )
                                    }
                                    cell.saveRequested = { [weak self] in
                                        self?.actionRequested?(.saveAttachment(messageID: message.id, attachment: .mediaGroup(group)))
                                    }
                                    cell.configure(
                                        message,
                                        group: group,
                                        frontIndex: mediaStackStateStore.index(
                                            for: message.id,
                                            itemCount: group.items.count
                                        ),
                                        strings: mediaStrings,
                                        saveState: saveState(for: message)
                                    )
                                    configureMessageMenu(cell, message: message)
                                }
                                .contextMenuPreview(highlighting: { [weak self] _ in
                                    self?.messageMenuCoordinator.preview(for: message.id)
                                }, dismissal: { [weak self] _ in
                                    self?.messageMenuCoordinator.preview(for: message.id, dismissing: true)
                                })
                                .refreshID(saveRefreshIdentity(message))
                                .refresh(when: .automatic, action: .reconfigure(layout: .invalidate))
                            }
                        }

                    case .typing(let accessibilityLabel):
                        Row(
                            model: accessibilityLabel,
                            cell: TypingCell.self
                        ) { cell, accessibilityLabel, _ in
                            cell.configure(
                                accessibilityLabel: accessibilityLabel
                            )
                        }
                        .refreshID(accessibilityLabel)
                    }
                }
            }
            .selectionMode(.none)
            .layout(timelineSectionLayout)
        }
        if restoresHistoryAnchor, let localizationAnchor, !pendingExplicitScroll,
           collectionView.numberOfSections > 0,
           collectionView.numberOfItems(inSection: 0) == state.timeline.count {
            // 无动画插入在返回主循环前恢复位置，完成回调再校正自适应高度。
            collectionView.layoutIfNeeded()
            collectionView.restoreLocalizationAnchor(localizationAnchor)
            collectionView.layoutIfNeeded()
            collectionView.restoreLocalizationAnchor(localizationAnchor)
        }
        if insertsText && (reason == .sentMessage || wasNearBottom) {
            // 无动画 snapshot 已提交，但 ListKit 的完成回调会延迟到下一次主线程调度。
            // 在首帧绘制前先完成自适应测量和定位，后续状态提交仍保留底部跟随。
            collectionView.layoutIfNeeded()
            scrollToBottom(animated: false)
            pendingExplicitScroll = true
        }
    }

    /// 更新后续媒体单元格配置使用的本地化文字集合。
    func configureMediaStrings(_ strings: MediaStrings) {
        mediaStrings = strings
    }

    /// 将页面级播放状态应用到可见的音频消息 Cell。
    ///
    /// 屏幕外的 Cell 会在 ListKit 配置时接收相同状态。
    ///
    /// - Parameter playback: 当前音频消息播放状态。
    func updateAudioPlayback(_ playback: PlaybackState) {
        playbackState = playback
        for case let cell as AudioBubbleCell
                in collectionView.visibleCells {
            cell.updatePlayback(
                playback,
                playAccessibilityLabel: Localization.text(
                    "imessage.audio.play"
                ),
                pauseAccessibilityLabel: Localization.text(
                    "imessage.audio.pause"
                )
            )
        }
    }

    /// 应用指定布局方向并重建集合布局，同时尽量保留当前可见消息位置。
    func applyLayoutDirection(
        _ direction: UIUserInterfaceLayoutDirection
    ) {
        lastAppliedLayoutDirection = direction
        collectionView.applyLocalization(
            Localization.layoutDirectionUpdate(direction),
            preservingVisibleItem: true,
            rebuildingLayoutWith: { [unowned self] in
                makeCollectionViewLayout()
            }
        )
    }

    /// 将最后一个时间线项目滚动到可见区域底部；列表为空时直接返回。
    func scrollToBottom(animated: Bool) {
        debugLogScroll("bottom.begin", detail: "animated=\(animated)")
        defer { debugLogScroll("bottom.end", detail: "animated=\(animated)") }
        guard collectionView.numberOfSections > 0 else { return }
        let section = collectionView.numberOfSections - 1
        let itemCount = collectionView.numberOfItems(inSection: section)
        guard itemCount > 0 else { return }
        // 长历史中的滚动尚未抵达底部时，送达/已读刷新不得恢复中途的阅读锚点。
        pendingExplicitScroll = animated && !isNearBottom
        collectionView.scrollToItem(
            at: IndexPath(item: itemCount - 1, section: section),
            at: .bottom,
            animated: animated
        )
    }

    /// 指示当前滚动位置距离内容底部不超过 88 点的布尔值。
    var isNearBottom: Bool {
        collectionView.layoutIfNeeded()
        let minimumOffset = -collectionView.adjustedContentInset.top
        let maximumOffset = max(
            minimumOffset,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        return maximumOffset - collectionView.contentOffset.y <= 88
    }

    /// 重查稳定身份，供菜单和执行入口共同使用。
    func message(for target: MessageMenuTarget) -> MessagePresentation? {
        lastState?.timeline.compactMap { item -> MessagePresentation? in
            guard case .message(let message) = item.content, target.matches(message) else { return nil }
            return message
        }.first
    }

    @objc private func dismissSelectionOutside(_ gesture: UITapGestureRecognizer) {
        for cell in collectionView.visibleCells.compactMap({ $0 as? TextBubbleCell }) {
            let text = cell.bubbleView.messageTextView
            if text.isSelectingMessageText && text.bounds.contains(gesture.location(in: text)) { return }
        }
        endMessageSelection()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    /// 刷新系统菜单与可见 Cell 的 VoiceOver 动作，使保存状态和权限变化同步生效。
    func refreshMenuAccessibility() {
        messageMenuCoordinator.refresh()
        for cell in collectionView.visibleCells {
            switch cell {
            case let cell as TextBubbleCell: cell.messageMenu.refreshAccessibility()
            case let cell as AudioBubbleCell: cell.messageMenu.refreshAccessibility()
            case let cell as DocumentBubbleCell: cell.messageMenu.refreshAccessibility()
            case let cell as MediaBubbleCell: cell.messageMenu.refreshAccessibility()
            default: break
            }
        }
    }

    func endMessageSelection() {
        for cell in collectionView.visibleCells.compactMap({ $0 as? TextBubbleCell }) {
            cell.bubbleView.messageTextView.endMessageSelection()
        }
    }

    func selectMessageText(_ target: MessageMenuTarget) {
        guard message(for: target) != nil,
              let index = lastState?.timeline.firstIndex(where: { $0.id == .message(target.messageID) }),
              let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? TextBubbleCell else { return }
        endMessageSelection()
        cell.bubbleView.messageTextView.beginMessageSelection()
    }

    /// 获取消息 Cell 的辅助功能及来源绑定，时间、状态等非消息行返回 `nil`。
    ///
    /// - Parameter cell: 列表当前持有的单元格。
    /// - Returns: 对应内容类型的绑定对象；不支持菜单的行返回 `nil`。
    private func menuBinding(for cell: UICollectionViewCell) -> MessageMenuAccessibility? {
        switch cell {
        case let cell as TextBubbleCell: cell.messageMenu
        case let cell as AudioBubbleCell: cell.messageMenu
        case let cell as DocumentBubbleCell: cell.messageMenu
        case let cell as MediaBubbleCell: cell.messageMenu
        default: nil
        }
    }

    /// 根据最新消息和保存状态生成指定目标的菜单项。
    ///
    /// - Parameter target: 菜单或辅助功能操作请求的稳定内容身份。
    /// - Returns: 当前策略允许显示的菜单项；消息或附件已失效时为空数组。
    private func menuItems(for target: MessageMenuTarget) -> [MessageMenuItem] {
        guard let message = message(for: target) else { return [] }
        return MessageMenuPolicy.items(for: message, target: target, saveState: menuSaveState?(target) ?? .available)
    }

    /// 按 Cell 当前绑定的身份查找，避免新模型和仍在应用中的旧 snapshot 索引混用。
    ///
    /// - Parameter target: 要求精确匹配的消息、附件及媒体项身份。
    /// - Returns: 当前可见且身份一致的来源；目标已删除、离屏或封面变化时为 `nil`。
    private func menuSource(for target: MessageMenuTarget) -> MessageMenuAccessibility.Source? {
        guard message(for: target) != nil else { return nil }
        return collectionView.visibleCells.compactMap { menuBinding(for: $0)?.source }
            .first { $0.target == target }
    }

    /// 返回指定菜单目标当前可见的源视图，供附件查看定位及回归验证使用。
    ///
    /// - Parameter target: 需要查找的稳定内容身份。
    /// - Returns: 身份匹配的真实内容视图；没有可见来源时为 `nil`。
    func menuSourceView(for target: MessageMenuTarget) -> UIView? { menuSource(for: target)?.view }

    /// 页面退出或主动清理时关闭菜单、取消待执行动作并释放保留的显示内容。
    func invalidateMessageMenu() { messageMenuCoordinator.invalidate() }

    /// 接收 ListKit 转发的系统菜单关闭通知，由协调对象校验会话并等待动画完成。
    ///
    /// - Parameters:
    ///   - collectionView: 正在关闭菜单的聊天列表。
    ///   - configuration: 本次关闭对应的系统菜单配置。
    ///   - animator: 系统关闭动画对象；为 `nil` 时由协调对象立即完成清理。
    func collectionView(_ collectionView: UICollectionView,
                        willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
                        animator: (any UIContextMenuInteractionAnimating)?) {
        messageMenuCoordinator.willEnd(configuration, animator: animator)
    }

    /// 为消息 Cell 绑定实时来源与 VoiceOver 动作，长按入口仍由列表统一提供。
    ///
    /// - Parameters:
    ///   - cell: 已完成消息内容配置的 Cell。
    ///   - message: 本次绑定的消息，用于建立稳定目标和附件身份。
    private func configureMessageMenu(_ cell: UICollectionViewCell, message: MessagePresentation) {
        var target = MessageMenuTarget(messageID: message.id)
        if case .attachment(let attachment) = message.content { target.attachmentID = attachment.id }
        let menu: MessageMenuAccessibility
        let accessibilityView: UIView
        let source: () -> MessageMenuAccessibility.Source?
        switch cell {
        case let cell as TextBubbleCell:
            menu = cell.messageMenu
            accessibilityView = cell.bubbleView.messageTextView
            cell.bubbleView.messageTextView.usesMessageMenu = true
            source = { [weak cell] in
                guard let cell, !cell.bubbleView.messageTextView.isSelectingMessageText else { return nil }
                return .init(target: target, view: cell.bubbleView, path: cell.bubbleView.menuPreviewPath)
            }
        case let cell as AudioBubbleCell:
            menu = cell.messageMenu
            accessibilityView = cell.bubbleView.playButton
            source = { [weak cell] in
                guard let cell else { return nil }
                return .init(target: target, view: cell.bubbleView,
                             path: cell.bubbleView.menuPreviewPath)
            }
        case let cell as DocumentBubbleCell:
            menu = cell.messageMenu
            accessibilityView = cell.card
            source = { [weak cell] in
                guard let cell else { return nil }
                return .init(target: target, view: cell.card,
                             path: UIBezierPath(roundedRect: cell.card.bounds, cornerRadius: cell.card.layer.cornerRadius))
            }
        case let cell as MediaBubbleCell:
            menu = cell.messageMenu
            accessibilityView = cell.mediaView
            // 每次查询时读取最前媒体项；菜单建立后由协调对象锁定该身份，不缓存索引位置。
            source = { [weak cell] in
                guard let view = cell?.mediaView, let group = view.group, group.items.indices.contains(view.frontMediaIndex),
                      let preview = view.previewSourceView else { return nil }
                var selected = target
                selected.mediaItemID = group.items[view.frontMediaIndex].id
                return .init(target: selected, view: preview,
                             path: view.menuPreviewPath,
                             canPresent: !view.isAnimating && view.interaction == nil)
            }
        default: return
        }
        menu.configure(accessibilityView: accessibilityView, source: source, items: { [weak self] in
            self?.menuItems(for: $0) ?? []
        }, canOpen: { [weak self] target in
            guard let message = self?.message(for: target), let attachment = target.attachment(in: message) else { return false }
            if case .audio = attachment { return false }
            return true
        }, open: { [weak self] in self?.openMenuAttachment?($0) },
           perform: { [weak self] operation, target in self?.actionRequested?(.menu(operation, target)) })
    }

    /// 配置集合视图的滚动、键盘、辅助功能及组合布局行为。
    private func configureCollectionView() {
        backgroundColor = .systemBackground
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.automaticallyAdjustsScrollIndicatorInsets = false
        collectionView.accessibilityIdentifier = "imessage.timeline"
        collectionView.collectionViewLayout = makeCollectionViewLayout()
    }

    /// 创建不自动引用系统内容内边距的垂直时间线组合布局。
    private func makeCollectionViewLayout()
        -> UICollectionViewCompositionalLayout {
        adapter.makeCompositionalLayout(
            configuration: ListCompositionalLayoutConfiguration(
                scrollDirection: .vertical,
                interSectionSpacing: 0,
                contentInsetsReference: .none
            )
        )
    }

    /// 在全屏容器内收窄消息行，左右安全区不作为 UIScrollView 的额外滚动边距。
    ///
    /// provider 每次失效时读取最新物理边距，再转换成语义边距，兼容折叠、旋转与 RTL。
    private var timelineSectionLayout: ListCustomSectionLayout<Section> {
        ListCustomSectionLayout(id: Section.timeline) { [weak self] _, _, _ in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .estimated(52))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            let insets = self?.viewportInsets ?? .zero
            let isRTL = self?.collectionView.effectiveUserInterfaceLayoutDirection == .rightToLeft
            section.contentInsetsReference = .none
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 10, leading: isRTL ? insets.right : insets.left,
                bottom: 10, trailing: isRTL ? insets.left : insets.right
            )
            section.interGroupSpacing = 2
            return section
        }
    }

    /// 向已经物化的单元格重新应用当前布局方向，并保留可见项目位置。
    private func refreshMaterializedContentLayoutDirection() {
        guard collectionView.window != nil
                || collectionView.semanticContentAttribute != .unspecified else {
            return
        }
        let direction = lastAppliedLayoutDirection
            ?? collectionView.effectiveUserInterfaceLayoutDirection
        collectionView.applyLocalization(
            Localization.layoutDirectionUpdate(
                direction,
                reasons: [.layoutDirection, .configuration]
            ),
            preservingVisibleItem: true
        )
    }
}

#if DEBUG
/// 创建指定布局方向、使用固定时间线数据的会话列表预览。
@available(iOS 17.0, *)
@MainActor
private func makeConversationPreview(
    direction: UIUserInterfaceLayoutDirection
) -> UIViewController {
    let conversationView = ConversationView(frame: .zero)
    conversationView.applyLayoutDirection(direction)
    conversationView.render(ConversationPreviewData.state, reason: .initial)
    return QuickLayoutHostingController {
        conversationView.resizable().frame(width: 390, height: 560)
    }
}

@available(iOS 17.0, *)
#Preview("消息会话列表") {
    makeConversationPreview(direction: .leftToRight)
}

@available(iOS 17.0, *)
#Preview("消息会话列表 · RTL") {
    makeConversationPreview(direction: .rightToLeft)
}
#endif
