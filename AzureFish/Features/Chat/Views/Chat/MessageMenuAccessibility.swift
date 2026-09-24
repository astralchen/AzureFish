import AppLocalization
import UIKit

/// Cell 只保存辅助功能绑定；长按交互由 ListKit 所在的列表统一拥有。
@MainActor
final class MessageMenuAccessibility {
    /// 当前 Cell 的内容身份、真实源视图、裁剪轮廓和交互可用性。
    struct Source {
        /// 当前消息、附件和媒体项的稳定身份，用于长按与辅助功能操作的目标校验。
        let target: MessageMenuTarget
        /// 提供高亮内容的真实气泡或最前附件卡片，不包含行内空白和外围按钮。
        let view: UIView
        /// 以 `view.bounds` 为坐标空间的内容轮廓；为 `nil` 时使用系统默认轮廓。
        var path: UIBezierPath? = nil
        /// 当前是否允许菜单操作，默认允许；文字选择或媒体切换期间应设为 `false`。
        var canPresent = true
    }

    /// 承载自定义辅助功能动作的内容元素，不由绑定对象强持有。
    private weak var accessibilityView: UIView?
    /// 按需查询 Cell 当前内容，复用解绑后为 `nil`。
    private var sourceProvider: (() -> Source?)?
    /// 查询指定目标最新的菜单项及可用状态。
    private var items: ((MessageMenuTarget) -> [MessageMenuItem])?
    /// 将辅助功能选中的操作与当前目标交付给页面处理。
    private var perform: ((MessageMenuOperation, MessageMenuTarget) -> Void)?
    /// 打开目标附件的完整查看入口，不创建长按内容预览。
    private var open: ((MessageMenuTarget) -> Void)?
    /// 查询目标是否支持完整查看；语音等具有独立交互的内容不提供此入口。
    private var canOpen: ((MessageMenuTarget) -> Bool)?
    /// 本对象安装的动作实例，用于精确移除而不影响内容元素已有的其他动作。
    private var actions: [UIAccessibilityCustomAction] = []

    /// 按需查询最新前卡片及其几何，避免缓存复用前的 Cell 内容。
    var source: Source? { sourceProvider?() }

    /// 将 VoiceOver 动作绑定到内容元素；重配前移除本对象安装的旧动作。
    ///
    /// - Parameters:
    ///   - accessibilityView: VoiceOver 聚焦的文字、播放按钮或附件卡片元素。
    ///   - source: 返回当前源视图及稳定身份；Cell 已失效时返回 `nil`。
    ///   - items: 根据目标实时生成菜单操作。
    ///   - canOpen: 判断当前附件是否有完整查看入口。
    ///   - open: 用户选择“打开预览”时调用的完整查看操作。
    ///   - perform: 用户选择其他辅助功能动作时调用的页面操作。
    func configure(accessibilityView: UIView, source: @escaping () -> Source?,
                   items: @escaping (MessageMenuTarget) -> [MessageMenuItem],
                   canOpen: @escaping (MessageMenuTarget) -> Bool,
                   open: @escaping (MessageMenuTarget) -> Void,
                   perform: @escaping (MessageMenuOperation, MessageMenuTarget) -> Void) {
        reset()
        self.accessibilityView = accessibilityView
        sourceProvider = source
        self.items = items
        self.canOpen = canOpen
        self.open = open
        self.perform = perform
        refreshAccessibility()
    }

    /// Cell 复用时解除旧消息的动作和源视图绑定。
    func reset() {
        removeActions()
        sourceProvider = nil
        items = nil
        canOpen = nil
        open = nil
        perform = nil
    }

    /// 保留其他辅助功能动作，只刷新当前内容可用的消息动作与完整查看入口。
    func refreshAccessibility() {
        removeActions()
        guard let source, let items else { return }
        actions = items(source.target).filter(\.isEnabled).map { item in
            UIAccessibilityCustomAction(name: Localization.text(item.titleKey)) { [weak self] _ in
                // VoiceOver 可以延后执行已列出的动作；执行时重查来源和权限，避免沿用旧封面状态。
                guard let self, let current = self.source, current.canPresent,
                      self.items?(current.target).contains(where: { $0.operation == item.operation && $0.isEnabled }) == true else { return false }
                self.perform?(item.operation, current.target)
                return true
            }
        }
        if canOpen?(source.target) == true {
            actions.append(UIAccessibilityCustomAction(name: Localization.text("imessage.media.openPreview")) { [weak self] _ in
                guard let self, let current = self.source, current.canPresent,
                      self.canOpen?(current.target) == true else { return false }
                self.open?(current.target)
                return true
            })
        }
        accessibilityView?.accessibilityCustomActions = (accessibilityView?.accessibilityCustomActions ?? []) + actions
    }

    /// 按对象身份移除本次绑定安装的动作，保留调用方原有的其他辅助功能操作。
    private func removeActions() {
        accessibilityView?.accessibilityCustomActions?.removeAll { old in actions.contains { $0 === old } }
        actions.removeAll()
    }
}
