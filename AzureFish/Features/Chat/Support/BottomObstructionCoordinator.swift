//
//  BottomObstructionCoordinator.swift
//  Demo
//
//  跟随照片选择器移动，并以最近一次系统键盘高度限制输入栏抬升。
//

import QuickLayoutKit
import UIKit

/// 统一管理输入栏的遮挡来源：键盘、照片面板，以及两者之间的交接阶段。
///
/// 所有高度均以宿主坐标计算，并扣除页面已承担的底部安全区。
/// 照片面板接管期间，上限保持为打开时的稳定键盘内容高度；入场期间保持键盘等高，
/// 切回键盘时先保留起点，再采用通知目标高度，避免跟随两个反向动画而让输入栏下坠。
@MainActor
final class BottomObstructionCoordinator {
    /// 显示链接持有代理，代理弱引用协调器，避免定时回调反向延长页面生命周期。
    @MainActor
    private final class DisplayLinkProxy {
        /// 接收显示链接回调的协调器；弱引用避免循环持有。
        weak var owner: BottomObstructionCoordinator?

        /// 在显示链接触发时通知协调器重新采样遮挡几何。
        @objc func tick() {
            owner?.refreshGeometry()
        }
    }

    /// 用于统一键盘和照片面板坐标的宿主视图。
    private weak var hostView: UIView?
    /// 当前跟踪的照片选择器；弱引用不延长其展示生命周期。
    private weak var pickerViewController: UIViewController?
    /// 将显示链接回调转发给协调器的弱引用代理。
    private let displayLinkProxy = DisplayLinkProxy()
    /// 逐帧跟踪键盘和照片面板几何的显示链接。
    private var displayLink: CADisplayLink?
    /// 最近一次系统键盘事件的上下文，包括可见性与动画信息。
    private var keyboardContext: QuickLayoutKeyboardContext?
    /// 从可见键盘切入照片时冻结高度，不能跟随面板从屏幕外升起而先下落。
    private var pickerPresentationHeight: CGFloat?
    /// 系统悬浮面板的实际顶部与键盘顶部略有差异；以展示完成的位置校准后续拖动。
    private var pickerGeometryOffset: CGFloat = 0
    /// 交接前输入栏的实际抬升量；面板消失而键盘通知尚未到达时仍可使用。
    private var keyboardHandoffStartHeight: CGFloat?
    /// 通知声明的键盘最终高度，与逐帧采样的动画中间高度分开保存。
    private var keyboardHandoffTargetHeight: CGFloat?
    /// 指示照片面板正在将底部遮挡交还给键盘的布尔值。
    private var isAwaitingKeyboard = false
    /// 当前发布的底部内容遮挡高度，已扣除安全区，单位为点。
    private(set) var currentHeight: CGFloat = 0
    /// 首次未显示过软件键盘时使用 300pt；面板接管后冻结，避免菜单临时通知改小上限。
    private(set) var storedKeyboardContentHeight: CGFloat = 300

    /// 有效遮挡高度变化时调用的闭包，附带可选的键盘动画上下文。
    var heightDidChange: ((CGFloat, QuickLayoutKeyboardContext?) -> Void)?

    /// 创建以指定宿主视图为坐标参照的遮挡协调器。
    init(hostView: UIView) {
        self.hostView = hostView
        displayLinkProxy.owner = self
    }

    /// 更新键盘状态，并返回该事件是否可以驱动 Composer 与列表布局。
    ///
    /// 照片 Sheet 展示且尚未开始切回键盘时返回 `false`，保留打开时的高度上限；
    /// 调用方不得据此滚动列表或更新输入栏位置。
    @discardableResult
    func updateKeyboard(_ context: QuickLayoutKeyboardContext) -> Bool {
        let shouldApplyKeyboardLayout = Self.shouldApplyKeyboardLayout(
            isPickerPresented: pickerViewController != nil,
            isAwaitingKeyboard: isAwaitingKeyboard
        )
        // 即使面板正在接管，也保留最新可见状态，供面板关闭时判断是否还有键盘遮挡；
        // 保存通知不代表允许它更新高度上限或立即驱动页面布局。
        keyboardContext = context
        if context.isVisible {
            if let hostView {
                let targetHeight = targetKeyboardContentHeight(
                    for: context,
                    in: hostView
                )
                if isAwaitingKeyboard {
                    keyboardHandoffTargetHeight = targetHeight
                }
                // 输入法切换、候选栏变化也要更新上限；交互收键盘的局部遮挡
                // 不代表新的键盘高度，不能把照片 Sheet 的上限逐帧缩小。
                if shouldApplyKeyboardLayout,
                   targetHeight > 0,
                   context.resolved(in: hostView).keyboardFrameInView.maxY
                    <= hostView.bounds.maxY + 0.5 {
                    storedKeyboardContentHeight = targetHeight
                }
            }
        }

        let shouldTrackGeometry = Self.shouldTrackGeometry(
            isPickerPresented: pickerViewController != nil,
            isAwaitingKeyboard: isAwaitingKeyboard,
            keyboardIsVisible: context.isVisible
        )
        if shouldTrackGeometry {
            startDisplayLink()
        } else {
            stopDisplayLink()
        }

        // 附件菜单关闭时 UIKit 可能再次报告移除候选栏后的临时键盘高度。
        // 照片 Sheet 已按打开时的高度创建，此时必须保留同一上限，避免输入栏
        // 上限变小而面板高度不变。只有明确切回键盘后才恢复缓存和键盘布局。
        guard shouldApplyKeyboardLayout else { return false }
        refreshGeometry(animationContext: context)
        return true
    }

    /// 必须在收起键盘和开始展示面板之前调用，先屏蔽转场期间的临时键盘高度。
    /// 此处清除上次交接状态，但保留稳定键盘高度供本次面板限位使用。
    func trackPicker(_ picker: UIViewController) {
        if let hostView, let keyboardContext,
           targetKeyboardContentHeight(for: keyboardContext, in: hostView) > 0 {
            pickerPresentationHeight = storedKeyboardContentHeight
        } else {
            // 直接打开照片或使用外接、浮动键盘时，输入栏仍随面板从底部正常升起。
            pickerPresentationHeight = nil
        }
        pickerGeometryOffset = 0
        pickerViewController = picker
        keyboardHandoffStartHeight = nil
        keyboardHandoffTargetHeight = nil
        isAwaitingKeyboard = false
        startDisplayLink()
        refreshGeometry()
    }

    /// 入场完成后才恢复面板几何跟随，并保留键盘顶部的原有位置。
    /// 系统悬浮边缘和缩放会让实际小档高度略小于键盘高度，直接解冻会产生几像素跳动。
    func finishPickerPresentation(_ picker: UIViewController) {
        // 旧面板的异步完成回调不得影响已经关闭或重新打开的面板。
        guard pickerViewController === picker else { return }
        if let height = pickerPresentationHeight,
           let hostView,
           let pickerHeight = visiblePickerHeight(in: hostView) {
            pickerGeometryOffset = max(0, height - pickerHeight)
        }
        pickerPresentationHeight = nil
        refreshGeometry()
    }

    /// 照片 Sheet 关闭前冻结当前遮挡，直到 keyboard layout guide 接管。
    func beginKeyboardHandoff() {
        pickerPresentationHeight = nil
        isAwaitingKeyboard = true
        keyboardHandoffStartHeight = currentHeight
        keyboardHandoffTargetHeight = nil
        startDisplayLink()
    }

    /// 仅在面板关闭完成后解除跟踪，确保关闭动画最后一帧仍能驱动输入栏。
    /// 若键盘交接尚未完成，则继续采样，不能随面板消失一起停止显示链接。
    func stopTrackingPicker() {
        pickerViewController = nil
        pickerPresentationHeight = nil
        pickerGeometryOffset = 0
        if isAwaitingKeyboard && keyboardContext?.isVisible != true {
            // 外接键盘不会产生可见的软件键盘。此时 Sheet 消失后没有新的
            // 遮挡源，必须解除交接冻结，避免输入栏停在旧 Sheet 顶部。
            isAwaitingKeyboard = false
            keyboardHandoffStartHeight = nil
            keyboardHandoffTargetHeight = nil
        }
        if keyboardContext?.isVisible != true && !isAwaitingKeyboard {
            stopDisplayLink()
        }
        refreshGeometry(animationContext: keyboardContext ?? .hidden)
    }

    /// 重新采样当前遮挡几何，不附加键盘通知的动画上下文。
    func refreshGeometry() {
        refreshGeometry(animationContext: nil)
    }

    /// 页面真正退出时停止采样并清除交接状态，避免离屏后继续驱动布局。
    func stop() {
        stopDisplayLink()
        pickerViewController = nil
        keyboardContext = nil
        pickerPresentationHeight = nil
        pickerGeometryOffset = 0
        keyboardHandoffStartHeight = nil
        keyboardHandoffTargetHeight = nil
        isAwaitingKeyboard = false
    }

    /// 解析当前遮挡来源，并仅在高度变化超过容差时发布更新。
    ///
    /// 先记录新高度再调用回调，避免同步布局造成重入发布。
    private func refreshGeometry(
        animationContext: QuickLayoutKeyboardContext?
    ) {
        guard let hostView else { return }
        let keyboardHeight = visibleKeyboardHeight(in: hostView)
        if isAwaitingKeyboard,
           pickerViewController == nil,
           let targetHeight = keyboardHandoffTargetHeight,
           abs(keyboardHeight - targetHeight) <= 0.5 {
            // Sheet 已经关闭且 keyboard layout guide 到达通知声明的最终高度后，
            // 才恢复逐帧键盘几何，避免两个反向动画产生中间低谷。
            isAwaitingKeyboard = false
            keyboardHandoffStartHeight = nil
            keyboardHandoffTargetHeight = nil
        }
        let resolved = Self.resolvedObstruction(
            keyboardHeight: keyboardHeight,
            pickerHeight: visiblePickerHeight(in: hostView),
            maximumPickerHeight: storedKeyboardContentHeight,
            pickerPresentationHeight: pickerPresentationHeight,
            pickerGeometryOffset: pickerGeometryOffset,
            isAwaitingKeyboard: isAwaitingKeyboard,
            keyboardHandoffStartHeight: keyboardHandoffStartHeight,
            keyboardHandoffTargetHeight: keyboardHandoffTargetHeight
        )
        // 过滤坐标转换和像素取整产生的微小变化，避免每一帧都重复布局、滚动列表。
        guard abs(resolved - currentHeight) > 0.5 else { return }
        // 回调会同步触发布局，布局又可能回到 refreshGeometry；先写入高度以阻止重入。
        currentHeight = resolved
        heightDidChange?(resolved, animationContext)
    }

    /// 返回键盘布局指南在指定视图中的有效遮挡高度；不可见时返回零。
    private func visibleKeyboardHeight(in view: UIView) -> CGFloat {
        guard keyboardContext?.isVisible == true else { return 0 }
        let frame = view.keyboardLayoutGuide.layoutFrame
        guard !frame.isNull, frame.minY < view.bounds.maxY else { return 0 }
        return Self.contentObstruction(
            containerMaxY: view.bounds.maxY,
            obstructionMinY: frame.minY,
            safeAreaBottom: view.safeAreaInsets.bottom
        )
    }

    /// 使用呈现层跟随 Sheet 的展开、拖动和关闭动画，避免模型层提前跳到终点。
    /// 坐标统一到宿主视图，并扣除已由页面布局承担的底部安全区。
    private func visiblePickerHeight(in view: UIView) -> CGFloat? {
        guard let pickerViewController else { return nil }
        guard let pickerView = pickerViewController.viewIfLoaded,
              let window = view.window,
              pickerView.window === window else {
            // present 调用前尚未进入窗口，保留现有位置直到首帧几何可用。
            return currentHeight
        }
        let frame: CGRect
        // 两端都使用呈现层，保证坐标转换包含系统面板父容器的缩放和位移动画；
        // 尚无呈现层时统一回退到视图坐标，避免混用模型层与呈现层坐标。
        if let pickerLayer = pickerView.layer.presentation(),
           let hostLayer = view.layer.presentation() {
            frame = pickerLayer.convert(pickerLayer.bounds, to: hostLayer)
        } else {
            frame = pickerView.convert(pickerView.bounds, to: view)
        }
        // 暂不截断负值：面板离开屏幕时需要先抵消几何校准量，再由统一解析器归零，
        // 否则输入栏会在关闭动画末尾残留几像素高度，直到 dismiss 完成才突然落底。
        return view.bounds.maxY - frame.minY - view.safeAreaInsets.bottom
    }

    /// 把键盘通知的最终 frame 转成不含底部安全区的稳定内容高度。
    private func targetKeyboardContentHeight(
        for context: QuickLayoutKeyboardContext,
        in view: UIView
    ) -> CGFloat {
        let resolved = context.resolved(in: view)
        // 浮动、分离或外接键盘不提供有效的底部停靠高度，不用于覆盖照片面板上限。
        guard context.isVisible,
              !resolved.isFloatingOrSplitKeyboard,
              !resolved.isHardwareKeyboardLikely else { return 0 }
        return max(resolved.height - view.safeAreaInsets.bottom, 0)
    }

    /// 页面已通过 safeAreaPadding 消费底部安全区，这里只返回需要额外补足的遮挡。
    /// 遮挡源退出屏幕后返回零，不能产生负间距把输入栏推到页面外。
    nonisolated static func contentObstruction(
        containerMaxY: CGFloat,
        obstructionMinY: CGFloat,
        safeAreaBottom: CGFloat
    ) -> CGFloat {
        max(containerMaxY - obstructionMinY - safeAreaBottom, 0)
    }

    /// 任一遮挡源存在或正在交接时持续采样，包括键盘已隐藏的照片 Sheet 动画。
    nonisolated static func shouldTrackGeometry(
        isPickerPresented: Bool,
        isAwaitingKeyboard: Bool,
        keyboardIsVisible: Bool
    ) -> Bool {
        isPickerPresented || isAwaitingKeyboard || keyboardIsVisible
    }

    /// 照片 Sheet 是当前遮挡源时，键盘事件不更新高度上限，也不驱动页面布局。
    nonisolated static func shouldApplyKeyboardLayout(
        isPickerPresented: Bool,
        isAwaitingKeyboard: Bool
    ) -> Bool {
        !isPickerPresented || isAwaitingKeyboard
    }

    /// 统一解析输入栏底部抬升量。
    ///
    /// 照片 Sheet 的实时遮挡以最近一次完整系统键盘内容高度为上限；继续展开到
    /// 大档时由系统覆盖下层内容。切回键盘期间保留交接起点，直到通知给出目标高度。
    nonisolated static func resolvedObstruction(
        keyboardHeight: CGFloat,
        pickerHeight: CGFloat?,
        maximumPickerHeight: CGFloat,
        pickerPresentationHeight: CGFloat? = nil,
        pickerGeometryOffset: CGFloat = 0,
        isAwaitingKeyboard: Bool = false,
        keyboardHandoffStartHeight: CGFloat? = nil,
        keyboardHandoffTargetHeight: CGFloat? = nil
    ) -> CGFloat {
        if isAwaitingKeyboard {
            // 交接优先于面板实时位置；即使面板已移出屏幕，也不能提前丢失交接起点。
            return max(
                0,
                keyboardHandoffTargetHeight ?? keyboardHandoffStartHeight ?? 0
            )
        }
        if let pickerHeight {
            if let pickerPresentationHeight {
                // 从键盘切入时，入场动画不改变输入栏位置；直接打开面板不经过此分支。
                return max(0, pickerPresentationHeight)
            }
            // 高于上限时停住，低于上限时双向跟随；不能使用 max，否则无法随面板下移。
            return max(0, min(pickerHeight + pickerGeometryOffset, maximumPickerHeight))
        }
        return max(0, keyboardHeight)
    }

    /// 按需创建显示链接，并在主运行循环的通用模式中跟踪几何。
    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: displayLinkProxy, selector: #selector(DisplayLinkProxy.tick))
        // 面板拖动和列表滚动会切换运行循环模式，加入 common 保证交互期间持续采样。
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// 使显示链接失效并解除持有，停止逐帧几何采样。
    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
}
