import Testing
import UIKit
@testable import AzureFish

/// 验证列表菜单的来源身份、显示快照、动作交付和 Cell 复用边界。
@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatMessageMenuPreviewTests {
    /// 创建已挂载到当前场景的测试窗口，使预览能够读取真实窗口与渲染内容。
    ///
    /// - Returns: 调用方应在测试结束时隐藏的窗口。
    /// - Throws: 测试宿主没有可用窗口场景时记录失败并抛出错误。
    private func window() throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        return window
    }

    /// 验证轮廓外命中被拒绝、几何按最新布局解析，以及目标缺失时不生成替代预览。
    @Test func hitTestingFreshGeometryAndMissingSource() throws {
        let window = try window()
        defer { window.isHidden = true }
        let list = UICollectionView(frame: window.bounds, collectionViewLayout: UICollectionViewFlowLayout())
        window.rootViewController!.view.addSubview(list)
        let bubble = UIView(frame: CGRect(x: 200, y: 200, width: 160, height: 80))
        list.addSubview(bubble)
        bubble.backgroundColor = .systemBlue
        let target = MessageMenuTarget(messageID: 1)
        var source: MessageMenuAccessibility.Source? = .init(target: target, view: bubble,
            path: UIBezierPath(roundedRect: bubble.bounds, cornerRadius: 20))
        let coordinator = MessageMenuCoordinator(collectionView: list, resolve: { _ in source },
            items: { _ in [.init(operation: .copy, titleKey: "imessage.menu.copy", symbol: "doc.on.doc")] }, perform: { _, _ in })
        #expect(coordinator.configuration(source: source!, point: CGPoint(x: 50, y: 240)) == nil)
        #expect(coordinator.configuration(source: source!, point: CGPoint(x: 200, y: 200)) == nil)
        source!.canPresent = false
        #expect(coordinator.configuration(source: source!, point: CGPoint(x: 240, y: 240)) == nil)
        source!.canPresent = true
        let config = try #require(coordinator.configuration(source: source!, point: CGPoint(x: 240, y: 240)))
        let first = try #require(coordinator.preview(for: 1))
        #expect(first.view === bubble)
        #expect(first.parameters.backgroundColor == .systemBlue)
        #expect(first.target.container === list)
        #expect(first.target.center == CGPoint(x: 280, y: 240))
        bubble.frame = CGRect(x: 120, y: 300, width: 200, height: 100)
        source!.path = UIBezierPath(roundedRect: bubble.bounds, cornerRadius: 20)
        let next = try #require(coordinator.preview(for: 1))
        #expect(next.parameters.visiblePath?.bounds == bubble.bounds)
        #expect(next.target.center == CGPoint(x: 220, y: 350))
        #expect(coordinator.preview(for: 2) == nil)
        source = nil
        #expect(coordinator.preview(for: 1) == nil)
        coordinator.willEnd(config, animator: nil)
        #expect(coordinator.target == nil)
    }

    /// 展开隐藏真实气泡，收起使用同一画面的快照；两个回调不依赖 willEnd 的调用顺序。
    @Test func textDismissalSnapshotPreservesSourceAndTracksGeometry() async throws {
        let window = try window()
        defer { window.isHidden = true }
        let list = UICollectionView(frame: window.bounds, collectionViewLayout: UICollectionViewFlowLayout())
        window.rootViewController!.view.addSubview(list)
        let bubble = TextBubbleView(frame: CGRect(x: 120, y: 220, width: 240, height: 82))
        bubble.configure(.init(id: 56, direction: .outgoing, text: "Original text\nSecond line", deliveryText: nil))
        list.addSubview(bubble)
        bubble.layoutIfNeeded()
        // snapshotView 读取已提交的显示内容；先让测试窗口完成首次绘制。
        try await Task.sleep(nanoseconds: 100_000_000)
        let target = MessageMenuTarget(messageID: 56)
        var exists = true
        let source = { MessageMenuAccessibility.Source(target: target, view: bubble, path: bubble.menuPreviewPath) }
        let coordinator = MessageMenuCoordinator(collectionView: list, resolve: { _ in exists ? source() : nil },
            items: { _ in [.init(operation: .copy, titleKey: "imessage.menu.copy", symbol: "doc.on.doc")] }, perform: { _, _ in })
        let config = try #require(coordinator.configuration(source: source(), point: CGPoint(x: 240, y: 250)))
        #expect(coordinator.preview(for: 56)?.view === bubble)
        let dismissal = try #require(coordinator.preview(for: 56, dismissing: true))
        #expect(dismissal.view !== bubble)
        #expect(dismissal.view.bounds.size == bubble.bounds.size)
        #expect(dismissal.parameters.visiblePath?.bounds == bubble.bounds)
        #expect(bubble.superview === list)
        #expect(bubble.alpha == 1 && !bubble.isHidden)
        let animator = MenuAnimator()
        coordinator.willEnd(config, animator: animator)
        #expect(coordinator.preview(for: 56, dismissing: true)?.view === dismissal.view)
        bubble.frame = CGRect(x: 100, y: 300, width: 220, height: 100)
        bubble.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let resized = try #require(coordinator.preview(for: 56, dismissing: true))
        #expect(resized.view !== dismissal.view)
        #expect(resized.view.bounds.size == bubble.bounds.size)
        #expect(resized.target.center == CGPoint(x: 210, y: 350))
        exists = false
        #expect(coordinator.preview(for: 56, dismissing: true) == nil)
        animator.finish()
        #expect(coordinator.target == nil)
    }

    /// 语音的完整已显示画面参与收起；展开保留真实来源，整个会话不得触发播放。
    ///
    /// - Parameter direction: 分别使用收到与发出的语音，覆盖不同填充颜色和尾部方向。
    @Test(arguments: [MessageDirection.incoming, .outgoing])
    func audioDismissalPreservesWaveformTranscriptAndPlayback(direction: MessageDirection) async throws {
        guard #available(iOS 17.0, *) else { return }
        let window = try window()
        defer { window.isHidden = true }
        let list = UICollectionView(frame: window.bounds, collectionViewLayout: UICollectionViewFlowLayout())
        window.rootViewController!.view.addSubview(list)
        let bubble = AudioBubbleView(frame: CGRect(x: 80, y: 220, width: 280, height: 130))
        let audio = AudioAttachment(fileURL: URL(fileURLWithPath: "/tmp/menu-audio.caf"),
            duration: 5, waveform: [0.2, 0.8, 0.4], transcript: "Original voice transcript")
        bubble.configure(attachment: audio, direction: direction, playback: .idle,
            playAccessibilityLabel: "Play", pauseAccessibilityLabel: "Pause")
        var playbackRequests = 0
        bubble.playbackRequested = { playbackRequests += 1 }
        list.addSubview(bubble)
        bubble.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let target = MessageMenuTarget(messageID: 57, attachmentID: audio.id)
        var exists = true
        let source = { MessageMenuAccessibility.Source(target: target, view: bubble, path: bubble.menuPreviewPath) }
        let coordinator = MessageMenuCoordinator(collectionView: list, resolve: { _ in exists ? source() : nil },
            items: { _ in [.init(operation: .share, titleKey: "imessage.menu.share", symbol: "square.and.arrow.up")] },
            perform: { _, _ in })
        for _ in 0..<3 {
            let config = try #require(coordinator.configuration(source: source(), point: CGPoint(x: 240, y: 250)))
            #expect(coordinator.preview(for: 57)?.view === bubble)
            let dismissal = try #require(coordinator.preview(for: 57, dismissing: true))
            #expect(dismissal.view !== bubble)
            #expect(dismissal.view.bounds.size == bubble.bounds.size)
            #expect(dismissal.parameters.visiblePath?.bounds == bubble.menuPreviewPath.bounds)
            let animator = MenuAnimator()
            coordinator.willEnd(config, animator: animator)
            #expect(coordinator.preview(for: 57, dismissing: true)?.view === dismissal.view)
            animator.finish()
            #expect(coordinator.target == nil)
            #expect(bubble.superview === list && !bubble.isHidden && bubble.alpha == 1)
            #expect(bubble.transcriptLabel.text == audio.transcript)
            #expect(bubble.waveformView.samples == audio.waveform)
            #expect(bubble.playButton.accessibilityLabel == "Play")
            #expect(playbackRequests == 0)
        }
        _ = coordinator.configuration(source: source(), point: CGPoint(x: 240, y: 250))
        exists = false
        #expect(coordinator.preview(for: 57, dismissing: true) == nil)
        coordinator.invalidate()
        #expect(coordinator.target == nil)
    }

    /// 验证操作等待关闭完成、只执行一次，且旧会话完成通知不能清理新菜单。
    @Test func actionsWaitForCompletionAndOldCompletionCannotAffectNewSession() throws {
        let window = try window()
        defer { window.isHidden = true }
        let list = UICollectionView(frame: window.bounds, collectionViewLayout: UICollectionViewFlowLayout())
        window.rootViewController!.view.addSubview(list)
        let bubble = UIView(frame: CGRect(x: 20, y: 100, width: 200, height: 80))
        list.addSubview(bubble)
        let target = MessageMenuTarget(messageID: 10, attachmentID: UUID(), mediaItemID: UUID())
        let source = MessageMenuAccessibility.Source(target: target, view: bubble)
        var valid = true
        var performed: [MessageMenuTarget] = []
        let coordinator = MessageMenuCoordinator(collectionView: list, resolve: { _ in source }, items: { _ in
            valid ? [.init(operation: .share, titleKey: "imessage.menu.share", symbol: "square.and.arrow.up")] : []
        }, perform: { _, target in performed.append(target) })
        /// 通过按钮触发菜单动作，模拟系统选中回调而不绕过动作内部的会话校验。
        func select(_ config: UIContextMenuConfiguration) throws {
            let menu = try #require(coordinator.menu(for: config))
            let group = try #require(menu.children.first as? UIMenu)
            let action = try #require(group.children.first as? UIAction)
            let button = UIButton(primaryAction: action)
            button.sendActions(for: .touchUpInside)
        }
        let first = try #require(coordinator.configuration(source: source, point: CGPoint(x: 40, y: 120)))
        try select(first)
        #expect(performed.isEmpty)
        let animator = MenuAnimator()
        coordinator.willEnd(first, animator: animator)
        #expect(performed.isEmpty)
        animator.finish()
        animator.finish()
        #expect(performed == [target])
        let old = try #require(coordinator.configuration(source: source, point: CGPoint(x: 40, y: 120)))
        try select(old)
        let closing = MenuAnimator()
        coordinator.willEnd(old, animator: closing)
        let new = try #require(coordinator.configuration(source: source, point: CGPoint(x: 40, y: 120)))
        closing.finish()
        #expect(coordinator.menu(for: new) != nil)
        #expect(performed == [target])
        try select(new)
        valid = false
        coordinator.refresh()
        coordinator.willEnd(new, animator: nil)
        #expect(coordinator.target == nil)
        #expect(performed == [target])
    }

    /// 验证动作晚于关闭动画到达时仍可执行，重复动作与主动失效后的动作均被忽略。
    @Test func actionDeliveredAfterDismissalStillExecutesOnlyOnce() throws {
        let window = try window()
        defer { window.isHidden = true }
        let list = UICollectionView(frame: window.bounds, collectionViewLayout: UICollectionViewFlowLayout())
        window.rootViewController!.view.addSubview(list)
        let bubble = UIView(frame: CGRect(x: 20, y: 100, width: 200, height: 80))
        list.addSubview(bubble)
        let source = MessageMenuAccessibility.Source(target: .init(messageID: 1), view: bubble)
        var count = 0
        let coordinator = MessageMenuCoordinator(collectionView: list, resolve: { _ in source },
            items: { _ in [.init(operation: .copy, titleKey: "imessage.menu.copy", symbol: "doc.on.doc")] },
            perform: { _, _ in count += 1 })
        let config = try #require(coordinator.configuration(source: source, point: CGPoint(x: 40, y: 120)))
        let group = try #require(coordinator.menu(for: config)?.children.first as? UIMenu)
        let action = try #require(group.children.first as? UIAction)
        let button = UIButton(primaryAction: action)
        coordinator.willEnd(config, animator: nil)
        #expect(count == 0)
        button.sendActions(for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        #expect(count == 1)
        coordinator.invalidate()
        button.sendActions(for: .touchUpInside)
        #expect(count == 1)
    }

    /// 验证菜单保留阻止离屏图片清理，但不能阻止 Cell 改绑文件时清除旧缩略图。
    @Test func retainedThumbnailSurvivesDismissalButNotReuse() throws {
        let image = MediaImageView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        image.setThumbnail(URL(fileURLWithPath: "/tmp/menu-thumbnail.jpg"))
        let displayed = UIImage(systemName: "photo")!
        image.image = displayed
        let release = MediaImageView.retainDisplayedContent(in: image)
        image.isContentActive = false
        #expect(image.image === displayed)
        image.setThumbnail(URL(fileURLWithPath: "/tmp/other-message.jpg"))
        #expect(image.image == nil)
        image.image = displayed
        release()
        release()
        #expect(image.image == nil)
    }

    /// 验证封面与保存状态刷新不改变锁定目标，页面退出后待执行动作失效。
    @Test func coverAndSaveRefreshKeepLockedTargetAndPageExitCancelsAction() throws {
        let window = try window()
        defer { window.isHidden = true }
        let list = UICollectionView(frame: window.bounds, collectionViewLayout: UICollectionViewFlowLayout())
        window.rootViewController!.view.addSubview(list)
        let card = UIView(frame: CGRect(x: 20, y: 100, width: 200, height: 120))
        list.addSubview(card)
        let first = MessageMenuTarget(messageID: 1, attachmentID: UUID(), mediaItemID: UUID())
        var second = first
        second.mediaItemID = UUID()
        let original = MessageMenuAccessibility.Source(target: first, view: card)
        var visible = original
        var enabled = true
        var performed: [MessageMenuTarget] = []
        let coordinator = MessageMenuCoordinator(collectionView: list, resolve: { _ in visible },
            items: { _ in [.init(operation: .save, titleKey: "imessage.menu.savePhoto", symbol: "square.and.arrow.down", isEnabled: enabled)] },
            perform: { _, target in performed.append(target) })
        let config = try #require(coordinator.configuration(source: original, point: CGPoint(x: 40, y: 120)))
        visible = .init(target: second, view: card)
        coordinator.refresh()
        #expect(coordinator.target == first)
        #expect(coordinator.preview(for: 1) == nil)
        #expect(coordinator.configuration(source: visible, point: CGPoint(x: 40, y: 120)) == nil)
        enabled = false
        coordinator.refresh()
        let disabledGroup = try #require(coordinator.menu(for: config)?.children.first as? UIMenu)
        #expect((disabledGroup.children.first as? UIAction)?.attributes.contains(.disabled) == true)
        enabled = true
        coordinator.refresh()
        let group = try #require(coordinator.menu(for: config)?.children.first as? UIMenu)
        let action = try #require(group.children.first as? UIAction)
        let button = UIButton(primaryAction: action)
        button.sendActions(for: .touchUpInside)
        let animator = MenuAnimator()
        coordinator.willEnd(config, animator: animator)
        coordinator.invalidate()
        animator.finish()
        button.sendActions(for: .touchUpInside)
        #expect(performed.isEmpty)
        #expect(coordinator.target == nil)
    }

    /// 验证 VoiceOver 刷新保留外部动作，Cell 复用时移除本次消息动作与来源绑定。
    @Test func accessibilityRefreshPreservesOtherActionsAndReuseRemovesOldBinding() throws {
        let view = UIView()
        let other = UIAccessibilityCustomAction(name: "Existing") { _ in true }
        view.accessibilityCustomActions = [other]
        let binding = MessageMenuAccessibility()
        binding.configure(accessibilityView: view, source: { .init(target: .init(messageID: 1), view: view) },
            items: { _ in [.init(operation: .copy, titleKey: "imessage.menu.copy", symbol: "doc.on.doc")] },
            canOpen: { _ in true }, open: { _ in }, perform: { _, _ in })
        binding.refreshAccessibility()
        #expect(view.accessibilityCustomActions?.count == 3)
        binding.reset()
        #expect(view.accessibilityCustomActions?.count == 1)
        #expect(view.accessibilityCustomActions?.first === other)
        #expect(binding.source == nil)
    }

    /// 通过真实列表代理验证 ListKit 菜单入口及历史前插后的身份解析，不直接替代 Row 回调。
    @Test func realListKitRoutesMenuAndKeepsSourceAfterHistoryInsertion() async throws {
        guard #available(iOS 26.0, *) else { return }
        let window = try window()
        defer { window.isHidden = true }
        let view = ConversationView(frame: window.bounds)
        window.rootViewController!.view = view
        let message = MessagePresentation(id: 5, direction: .outgoing, text: "Original bubble", deliveryText: nil)
        /// 将样例消息转换为时间线状态，保留消息稳定标识以模拟历史前插。
        func state(_ messages: [MessagePresentation]) -> ChatViewModel.State {
            .init(timeline: messages.map { .init(id: .message($0.id), content: .message($0)) }, isTyping: false)
        }
        view.render(state([message]), reason: .initial)
        for _ in 0..<30 { try await Task.sleep(nanoseconds: 20_000_000); view.layoutIfNeeded(); view.collectionView.layoutIfNeeded() }
        let list = view.collectionView
        let index = try #require(list.indexPathsForVisibleItems.first { list.cellForItem(at: $0) is TextBubbleCell })
        let cell = try #require(list.cellForItem(at: index) as? TextBubbleCell)
        #expect(cell.bubbleView.interactions.allSatisfy { !($0 is UIContextMenuInteraction) })
        let point = cell.bubbleView.convert(CGPoint(x: cell.bubbleView.bounds.midX, y: cell.bubbleView.bounds.midY), to: list)
        let config = try #require(list.delegate?.collectionView?(list, contextMenuConfigurationForItemsAt: [index], point: point))
        let preview = list.delegate?.collectionView?(list, contextMenuConfiguration: config, highlightPreviewForItemAt: index)
        #expect(preview?.view === cell.bubbleView)
        let older = MessagePresentation(id: 4, direction: .incoming, text: "Older history", deliveryText: nil)
        view.render(state([older, message]), reason: .olderHistoryLoaded)
        for _ in 0..<20 { try await Task.sleep(nanoseconds: 20_000_000); list.layoutIfNeeded() }
        let dismissal = list.delegate?.collectionView?(list, previewForDismissingContextMenuWithConfiguration: config)
        let currentSource = try #require(view.menuSourceView(for: .init(messageID: 5)))
        #expect(dismissal != nil)
        #expect(dismissal?.view !== currentSource)
        #expect(dismissal?.view.bounds.size == currentSource.bounds.size)
        view.render(state([older]), reason: .messageDeleted)
        #expect(view.menuSourceView(for: .init(messageID: 5)) == nil)
        view.invalidateMessageMenu()
    }
}

/// 可手动结束的系统菜单动画替身，用于覆盖动作回调与关闭回调的不同到达顺序。
@MainActor
private final class MenuAnimator: NSObject, UIContextMenuInteractionAnimating {
    /// 原视图高亮不创建独立预览控制器，因此始终返回 `nil`。
    var previewViewController: UIViewController? { nil }
    /// 按注册顺序保存的完成回调，供测试控制触发时机。
    var completions: [() -> Void] = []
    /// 立即执行动画闭包，测试只控制完成通知的交付时间。
    func addAnimations(_ animations: @escaping () -> Void) { animations() }
    /// 保存关闭完成回调，等待测试显式调用 `finish()`。
    func addCompletion(_ completion: @escaping () -> Void) { completions.append(completion) }
    /// 交付所有完成回调；保留数组以便重复调用，验证协调对象的幂等清理。
    func finish() { completions.forEach { $0() } }
}
