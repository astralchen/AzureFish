import AppLocalization
import UIKit

/// 一次列表菜单锁定一个内容身份，Cell 重配和历史前插不改变菜单的操作对象。
@MainActor
final class MessageMenuCoordinator {
    /// 由配置与动画共同持有的会话；释放已显示内容始终在主 actor 上完成。
    @MainActor
    private final class Session {
        /// 写入菜单配置的唯一标识，用于区分连续打开的不同会话。
        let id = UUID().uuidString
        /// 菜单开始时锁定的消息、附件和媒体项身份，不随列表重排或封面变化而修改。
        let target: MessageMenuTarget
        /// 用户选中的待执行操作；未选择或已经取消时为 `nil`。
        var operation: MessageMenuOperation?
        /// 是否已经收到本会话的关闭通知，初始为 `false`。
        var isEnding = false
        /// 页面退出或目标失效后置为 `true`，使已创建的动作回调失效。
        var isCancelled = false
        /// 资源释放是否已经完成，用于忽略重复的动画完成通知。
        var didComplete = false
        /// 待执行操作是否已经交付，防止动作回调与关闭回调重复执行。
        var didPerformAction = false
        /// 释放已显示媒体内容的主 actor 闭包；执行并清理后为 `nil`。
        var releaseContent: (() -> Void)?
        /// 与当前源视图及其已绘制尺寸对应的气泡收起画面。
        private var bubbleSnapshot: UIView?
        /// 不延长 Cell 的生命周期；源视图变化时重新捕获，不能沿用复用前的画面。
        private weak var bubbleSnapshotSource: UIView?

        /// 未收到关闭回调时仍释放本次保留的缩略图。
        isolated deinit { releaseContent?() }

        /// 锁定目标，并在 UIKit 遮挡来源前保留本次菜单所需的显示内容。
        ///
        /// - Parameter source: 已通过命中检查、仍在窗口中的消息来源。
        init(source: MessageMenuAccessibility.Source) {
            target = source.target
            releaseContent = MediaImageView.retainDisplayedContent(in: source.view)
            _ = dismissalView(for: source.view)
        }

        /// 文字与语音气泡的收起使用已显示画面，避免内容在系统解除来源遮挡前提前消失。
        /// 高亮仍使用真实气泡，让 UIKit 隐藏来源；全程使用独立快照会在下面露出原气泡。
        ///
        /// - Parameter source: 按稳定身份重新解析的当前源视图。
        /// - Returns: 文字或语音的显示快照；其他内容或快照捕获失败时返回源视图。
        func dismissalView(for source: UIView) -> UIView {
            let isAudioBubble: Bool
            if #available(iOS 17.0, *) { isAudioBubble = source is AudioBubbleView }
            else { isAudioBubble = false }
            guard source is TextBubbleView || isAudioBubble else { return source }
            if bubbleSnapshotSource !== source || bubbleSnapshot?.bounds.size != source.bounds.size {
                bubbleSnapshot = source.snapshotView(afterScreenUpdates: false)
                bubbleSnapshotSource = source
            }
            return bubbleSnapshot ?? source
        }

        /// 动画结束后释放画面；已经交给 UIKit 的目标预览自行持有它需要的视图。
        func releaseSnapshot() {
            bubbleSnapshot = nil
            bubbleSnapshotSource = nil
        }
    }

    /// 承载系统菜单与预览动画的列表；协调对象不延长列表生命周期。
    private weak var collectionView: UICollectionView?
    /// 以稳定身份查询当前可见来源；目标删除、离屏或被复用后返回 `nil`。
    private let resolve: (MessageMenuTarget) -> MessageMenuAccessibility.Source?
    /// 根据当前模型、保存状态和权限生成目标的可用操作。
    private let items: (MessageMenuTarget) -> [MessageMenuItem]
    /// 在关闭完成且目标重新校验通过后，将操作交付给页面。
    private let perform: (MessageMenuOperation, MessageMenuTarget) -> Void
    /// 当前正在展示或收起的菜单会话；资源清理完成后置为 `nil`。
    private var session: Session?
    /// 最近创建的会话标识，关闭后仍保留以接收迟到动作；新会话或主动取消会使旧标识失效。
    private var latestSessionID: String?

    /// 注入列表、稳定身份解析、实时权限查询和页面操作入口。
    ///
    /// - Parameters:
    ///   - collectionView: 通过 ListKit 提供菜单配置和生命周期回调的列表。
    ///   - resolve: 返回指定身份的当前可见来源，不得缓存会随分页变化的索引。
    ///   - items: 返回目标当前的菜单项；目标失效时返回空数组。
    ///   - perform: 执行已确认仍可用的操作，由页面继续处理权限与确认流程。
    init(collectionView: UICollectionView,
         resolve: @escaping (MessageMenuTarget) -> MessageMenuAccessibility.Source?,
         items: @escaping (MessageMenuTarget) -> [MessageMenuItem],
         perform: @escaping (MessageMenuOperation, MessageMenuTarget) -> Void) {
        self.collectionView = collectionView
        self.resolve = resolve
        self.items = items
        self.perform = perform
    }

    /// 当前会话锁定的消息及附件身份，关闭后返回 `nil`。
    var target: MessageMenuTarget? { session?.target }

    /// 仅在原内容轮廓内创建配置，并保留该帧已经显示的媒体内容。
    ///
    /// - Parameters:
    ///   - source: 当前命中 Cell 提供的内容身份、源视图及交互条件。
    ///   - point: 长按位置，使用列表的坐标系。
    /// - Returns: 关联本次会话的系统菜单配置；未命中内容、目标不可用或已有其他目标菜单时为 `nil`。
    func configuration(source: MessageMenuAccessibility.Source, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let collectionView, source.canPresent, source.view.window != nil,
              !source.view.isHidden, source.view.alpha > 0,
              source.view.bounds.contains(source.view.convert(point, from: collectionView)),
              !items(source.target).isEmpty else { return nil }
        let localPoint = source.view.convert(point, from: collectionView)
        if let path = source.path, !path.contains(localPoint) { return nil }
        // UIKit 可能重复询问同一手势；不替换正在展示的会话。
        if let session, !session.isEnding {
            guard !session.isCancelled, session.target == source.target else { return nil }
            return makeConfiguration(session)
        }
        let value = Session(source: source)
        session = value
        latestSessionID = value.id
        return makeConfiguration(value)
    }

    /// 不创建内容预览控制器；ListKit 的目标预览回调提供原视图。
    ///
    /// - Parameter value: 配置所属的会话，配置标识与该会话保持一致。
    /// - Returns: `previewProvider` 为 `nil`、按需生成动作菜单的配置。
    private func makeConfiguration(_ value: Session) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: value.id as NSString, previewProvider: nil) { [weak self, weak value] _ in
            guard let self, let value, !value.isCancelled else { return nil }
            return self.menu(value)
        }
    }

    /// 返回仍属于当前会话的菜单，便于验证配置与动作的关联。
    ///
    /// - Parameter configuration: ListKit 返回的菜单配置。
    /// - Returns: 当前会话的菜单；配置过期或会话已取消时为 `nil`。
    func menu(for configuration: UIContextMenuConfiguration) -> UIMenu? {
        guard let value = session, !value.isCancelled, configuration.identifier as? String == value.id else { return nil }
        return menu(value)
    }

    /// 按内容操作、重试和删除分组构建菜单，并为每项动作绑定会话身份。
    ///
    /// - Parameter value: 动作所属的会话，用户点击时重新检查其有效性与操作权限。
    /// - Returns: 反映当前权限与保存状态的菜单，删除操作标记为破坏性动作。
    private func menu(_ value: Session) -> UIMenu {
        let actions = items(value.target).map { item in
            var attributes: UIMenuElement.Attributes = item.isEnabled ? [] : [.disabled]
            if item.operation == .delete { attributes.insert(.destructive) }
            let action = UIAction(title: Localization.text(item.titleKey), image: UIImage(systemName: item.symbol),
                                  identifier: .init("imessage.menu.\(item.operation.rawValue)"), attributes: attributes) { [weak self, value] _ in
                guard let self, self.latestSessionID == value.id, !value.isCancelled, !value.didPerformAction,
                      self.items(value.target).contains(where: { $0.operation == item.operation && $0.isEnabled }) else { return }
                value.operation = item.operation
                // UIKit 的动作回调可能晚于 willEnd，甚至晚于关闭动画完成。
                // 两种顺序都通过同一个单次执行入口，关闭前只排队。
                if value.didComplete { self.performPendingAction(value) }
            }
            return (item.operation, action)
        }
        let groups: [[MessageMenuOperation]] = [[.copy, .selectText, .save, .share, .openLink], [.retry], [.delete]]
        return UIMenu(children: groups.compactMap { group in
            let children = actions.filter { group.contains($0.0) }.map(\.1)
            return children.isEmpty ? nil : UIMenu(options: .displayInline, children: children)
        })
    }

    /// 每次请求都重新读取真实几何；源 Cell 被复用或媒体封面改变时不返回错误目标。
    /// `dismissing` 由 Row 的收起回调显式传入，不以 willEnd 是否到达推断预览阶段。
    ///
    /// - Parameters:
    ///   - messageID: 发起预览请求的 Row 所对应的稳定消息标识。
    ///   - dismissing: 是否生成收起预览，默认为 `false`；为 `true` 时文字与语音使用显示快照。
    /// - Returns: 以列表为动画容器的内容预览；身份、可见性或窗口校验失败时为 `nil`。
    func preview(for messageID: Int, dismissing: Bool = false) -> UITargetedPreview? {
        guard let value = session, !value.isCancelled, value.target.messageID == messageID,
              let source = resolve(value.target), source.target == value.target,
              let collectionView, let window = collectionView.window, source.view.window === window,
              !source.view.isHidden, source.view.alpha > 0 else { return nil }
        let parameters = UIPreviewParameters()
        // UIKit 用此颜色绘制源视图背景；传 clear 会抹掉文字／语音气泡的底色。
        // visiblePath 外仍透明，填充仅限原气泡轮廓。
        parameters.backgroundColor = source.view.backgroundColor ?? .clear
        parameters.visiblePath = source.path
        // 媒体堆叠使用非零 zPosition；默认父容器中的收起快照会被后卡片遮挡。
        // 将动画放在列表层，终点仍使用原内容的真实中心。
        let center = source.view.convert(CGPoint(x: source.view.bounds.midX, y: source.view.bounds.midY), to: collectionView)
        let target = UIPreviewTarget(container: collectionView, center: center)
        let previewView = dismissing ? value.dismissalView(for: source.view) : source.view
        return UITargetedPreview(view: previewView, parameters: parameters, target: target)
    }

    /// 根据最新保存状态和权限刷新菜单；消息或附件失效时结束会话。
    func refresh() {
        guard let value = session, !value.isEnding else { return }
        guard !items(value.target).isEmpty else { invalidate(); return }
        collectionView?.contextMenuInteraction?.updateVisibleMenu { [weak self, weak value] old in
            guard let self, let value, self.session === value, !value.isCancelled else { return old }
            return self.menu(value)
        }
    }

    /// 接收 ListKit 转发的关闭生命周期，在动画完成后交付待执行动作。
    ///
    /// - Parameters:
    ///   - configuration: 正在关闭的配置；旧会话或重复关闭通知会被忽略。
    ///   - animator: 系统提供的关闭动画对象；为 `nil` 时立即完成资源清理与操作交付。
    func willEnd(_ configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        guard let value = session, configuration.identifier as? String == value.id, !value.isEnding else { return }
        value.isEnding = true
        if let animator { animator.addCompletion { [weak self] in self?.complete(value) } }
        else { complete(value) }
    }

    /// 幂等地释放会话资源；仅当前会话可以清空列表状态并交付待执行操作。
    ///
    /// - Parameter value: 已结束展示或被主动取消的会话。
    private func complete(_ value: Session) {
        guard !value.didComplete else { return }
        value.didComplete = true
        value.releaseContent?()
        value.releaseContent = nil
        value.releaseSnapshot()
        // 旧动画不能清理或操作后来打开的新菜单。
        guard session === value else { return }
        session = nil
        performPendingAction(value)
    }

    /// 重新校验最新会话、取消状态及操作权限，并至多执行一次待处理动作。
    ///
    /// - Parameter value: 已完成关闭的会话，也可能由关闭后才到达的动作回调持有。
    private func performPendingAction(_ value: Session) {
        guard latestSessionID == value.id, !value.isCancelled, !value.didPerformAction,
              let operation = value.operation,
              items(value.target).contains(where: { $0.operation == operation && $0.isEnabled }) else { return }
        value.didPerformAction = true
        perform(operation, value.target)
    }

    /// 页面退出或目标失效时取消动作与菜单，并使迟到回调失效。
    func invalidate() {
        latestSessionID = nil
        guard let value = session else { return }
        value.isCancelled = true
        value.operation = nil
        collectionView?.contextMenuInteraction?.dismissMenu()
        // 页面退出可以没有动画回调，保证保留的缩略图有确定释放点。
        complete(value)
    }

}
