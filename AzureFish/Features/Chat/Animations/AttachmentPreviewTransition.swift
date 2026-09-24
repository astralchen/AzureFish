import UIKit

/// 保持聊天和照片面板在预览下方存活的全屏 presentation。
private final class AttachmentPreviewPresentationController: UIPresentationController {
    override var shouldRemovePresentersView: Bool { false }
    override var frameOfPresentedViewInContainerView: CGRect { containerView?.bounds ?? .zero }
    override func containerViewWillLayoutSubviews() { presentedView?.frame = frameOfPresentedViewInContainerView }
}

/// 玻璃预览的卡片匹配转场及百分比交互驱动。
@available(iOS 26.0, *)
final class AttachmentPreviewTransition: NSObject, UIViewControllerTransitioningDelegate {
    private weak var preview: AttachmentPreviewController?
    private var driver: UIPercentDrivenInteractiveTransition?
    private var animator: AttachmentPreviewAnimator?
    private var finishing = false
    var isInteracting: Bool { driver != nil }
    init(preview: AttachmentPreviewController) { self.preview = preview }
    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        AttachmentPreviewPresentationController(presentedViewController: presented, presenting: presenting)
    }
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        let animator = AttachmentPreviewAnimator(preview: preview, presenting: true, interactive: false)
        animator.didEnd = { [weak self] in self?.animator = nil }
        self.animator = animator
        return animator
    }
    func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        let animator = AttachmentPreviewAnimator(preview: preview, presenting: false, interactive: isInteracting)
        animator.didEnd = { [weak self] in self?.driver = nil; self?.animator = nil; self?.finishing = false }
        self.animator = animator
        return animator
    }
    func interactionControllerForDismissal(using animator: any UIViewControllerAnimatedTransitioning) -> (any UIViewControllerInteractiveTransitioning)? { driver }

    /// 开始转场但保留内容播放状态，允许完全撤销关闭。
    func begin() {
        guard driver == nil, let preview, preview.presentingViewController != nil else { return }
        let driver = UIPercentDrivenInteractiveTransition()
        driver.completionCurve = .easeOut
        self.driver = driver
        preview.dismiss(animated: true)
    }
    func update(translation: CGPoint) {
        guard !finishing, let driver, let preview else { return }
        let progress = min(0.95, max(0, translation.y) / max(1, preview.view.bounds.height))
        driver.update(progress)
        animator?.moveSnapshot(translation: translation, progress: progress)
    }
    func end(translation: CGPoint, velocity: CGPoint) {
        guard let preview, let driver, !finishing else { return }
        finishing = true
        if AttachmentPreviewPolicy.shouldDismiss(distance: translation.y, velocity: velocity.y, height: preview.view.bounds.height) {
            animator?.settleSnapshot(closing: true) { driver.completionSpeed = 3; driver.finish() }
        } else {
            animator?.settleSnapshot(closing: false) { driver.cancel() }
        }
    }
    func cancel() {
        guard let driver, !finishing else { return }
        finishing = true
        animator?.settleSnapshot(closing: false) { driver.cancel() }
    }
}

/// 为每次转场持有同一个可中断动画器，集中恢复快照与来源视图。
@available(iOS 26.0, *)
private final class AttachmentPreviewAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private weak var preview: AttachmentPreviewController?
    private let presenting: Bool
    private let interactive: Bool
    private var propertyAnimator: UIViewPropertyAnimator?
    private var snapshot: UIView?
    private var fullFrame = CGRect.zero
    private var targetFrame: CGRect?
    private var targetRadius: CGFloat = 12
    private weak var source: UIView?
    private var sourceAlpha: CGFloat = 1
    private var originalChromeAlpha: CGFloat = 1
    var didEnd: (() -> Void)?
    init(preview: AttachmentPreviewController?, presenting: Bool, interactive: Bool) {
        self.preview = preview; self.presenting = presenting; self.interactive = interactive
    }
    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0.18 : (presenting ? 0.42 : 0.34)
    }
    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: transitionContext).startAnimation()
    }
    func interruptibleAnimator(using context: any UIViewControllerContextTransitioning) -> any UIViewImplicitlyAnimating {
        if let propertyAnimator { return propertyAnimator }
        let container = context.containerView
        guard let preview else { return UIViewPropertyAnimator(duration: 0, curve: .linear) { context.completeTransition(false) } }
        let view = preview.view!
        if presenting { container.addSubview(view); view.frame = context.finalFrame(for: preview) }
        view.layoutIfNeeded()
        originalChromeAlpha = preview.chrome.alpha
        let candidate = preview.sourceResolver?(preview.currentIndex, !presenting)
        if let candidate, Self.isVisible(candidate, in: container.window) {
            source = candidate
            sourceAlpha = candidate.alpha
            targetFrame = candidate.convert(candidate.bounds, to: container)
            targetRadius = max(0, candidate.layer.cornerRadius)
        }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let page = preview.currentPage
        let contentFrame = page.map { $0.convert($0.transitionRect, to: container) } ?? view.frame
        fullFrame = contentFrame
        if !reduceMotion, let page, let copy = page.transitionSnapshot(afterScreenUpdates: presenting) {
            copy.frame = presenting ? (targetFrame ?? contentFrame) : contentFrame
            copy.clipsToBounds = true
            copy.layer.cornerCurve = .continuous
            copy.layer.cornerRadius = presenting ? targetRadius : 0
            snapshot = copy
            container.addSubview(copy)
            source?.alpha = 0
            preview.collectionView.alpha = 0
        }
        if presenting { preview.backdrop.alpha = 0; preview.chrome.alpha = 0; if snapshot == nil { preview.collectionView.alpha = 0 } }
        let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), dampingRatio: 0.92)
        propertyAnimator = animator
        animator.addAnimations { [self] in
            preview.backdrop.alpha = presenting ? 1 : 0
            preview.chrome.alpha = presenting ? originalChromeAlpha : 0
            if snapshot == nil { preview.collectionView.alpha = presenting ? 1 : 0 }
            if !interactive {
                snapshot?.frame = presenting ? fullFrame : (targetFrame ?? fullFrame)
                snapshot?.layer.cornerRadius = presenting ? 0 : targetRadius
                snapshot?.alpha = presenting || targetFrame != nil ? 1 : 0
            }
        }
        animator.addCompletion { [self] _ in
            let completed = !context.transitionWasCancelled
            source?.alpha = sourceAlpha
            snapshot?.removeFromSuperview()
            snapshot = nil
            preview.collectionView.alpha = 1
            preview.backdrop.alpha = 1
            preview.chrome.alpha = originalChromeAlpha
            if presenting && !completed { view.removeFromSuperview() }
            if !presenting && completed { view.removeFromSuperview() }
            context.completeTransition(completed)
            if !presenting && completed { preview.completeDismissal() }
            didEnd?()
        }
        return animator
    }
    /// 拖动阶段让快照直接跟随手指，背景由 UIKit 的交互进度驱动。
    func moveSnapshot(translation: CGPoint, progress: CGFloat) {
        guard !UIAccessibility.isReduceMotionEnabled, let snapshot else { return }
        let scale = 1 - min(0.28, progress * 0.45)
        snapshot.transform = CGAffineTransform(translationX: translation.x, y: max(0, translation.y)).scaledBy(x: scale, y: scale)
        snapshot.layer.cornerRadius = min(24, progress * 80)
    }
    /// 松手后匹配来源或回弹，再完成／取消系统交互事务。
    func settleSnapshot(closing: Bool, completion: @escaping () -> Void) {
        guard let snapshot else { completion(); return }
        let animator = UIViewPropertyAnimator(duration: UIAccessibility.isReduceMotionEnabled ? 0.12 : 0.24, dampingRatio: 0.92)
        animator.addAnimations { [self] in
            snapshot.transform = .identity
            snapshot.frame = closing ? (targetFrame ?? fullFrame) : fullFrame
            snapshot.layer.cornerRadius = closing ? targetRadius : 0
            snapshot.alpha = closing && targetFrame == nil ? 0 : 1
        }
        animator.addCompletion { _ in completion() }
        animator.startAnimation()
    }
    /// 检查每层裁剪容器，离屏附件不作为收回目标。
    static func isVisible(_ view: UIView, in window: UIWindow?) -> Bool {
        guard let window, view.window === window, view.bounds.width > 0, view.bounds.height > 0 else { return false }
        var rect = view.convert(view.bounds, to: window)
        var current: UIView? = view
        while let ancestor = current {
            guard !ancestor.isHidden, ancestor.alpha > 0.01 else { return false }
            if ancestor.clipsToBounds { rect = rect.intersection(ancestor.convert(ancestor.bounds, to: window)) }
            current = ancestor.superview
        }
        return !rect.intersection(window.bounds).isEmpty
    }
}
