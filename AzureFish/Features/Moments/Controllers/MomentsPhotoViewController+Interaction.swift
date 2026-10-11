import UIKit

extension MomentsPhotoViewController {
    func toggleControls() {
        guard !closing, !draggingClose else { return }
        controlsHidden.toggle(); bar.alpha = controlsHidden ? 0 : 1
        bar.accessibilityElementsHidden = controlsHidden; setNeedsStatusBarAppearanceUpdate()
    }
    /// 仅在未缩放、未翻页时接受向下为主的关闭拖动，避免与图片操作争用。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return true }
        let velocity = dismissPan.velocity(in: view)
        return !invalidated && !closing && pendingIndex == nil && !collection.isDragging && !collection.isDecelerating && currentPage?.isZoomed != true && velocity.y > abs(velocity.x)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === dismissPan else { return true }
        if let touched = touch.view, touched.isDescendant(of: bar) { return false }
        return !(touch.view is UIControl)
    }
    /// 根据视图坐标中的下拉距离（点）、纵向速度（点／秒）和容器高度决定是否关闭。
    static func shouldClose(distance: CGFloat, velocity: CGFloat, height: CGFloat) -> Bool {
        distance > min(160, height * 0.2) || (distance > 40 && velocity > 900)
    }
    @objc func panned(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view), distance = max(0, translation.y)
        switch gesture.state {
        case .began:
            draggingClose = true; collection.isScrollEnabled = false; bar.alpha = 0
        case .changed:
            let fraction = min(1, distance / max(1, view.bounds.height * 0.5))
            backdrop.alpha = 1 - fraction
            if !UIAccessibility.isReduceMotionEnabled {
                collection.transform = CGAffineTransform(translationX: translation.x * 0.25, y: distance).scaledBy(x: 1 - fraction * 0.2, y: 1 - fraction * 0.2)
            }
        case .ended:
            if Self.shouldClose(distance: distance, velocity: gesture.velocity(in: view).y, height: view.bounds.height) { closePreview() }
            else { resetDismissal(animated: true) }
        case .cancelled, .failed: resetDismissal(animated: true)
        default: break
        }
    }
    func resetDismissal(animated: Bool) {
        draggingClose = false
        let changes = { self.collection.transform = .identity; self.backdrop.alpha = 1; self.bar.alpha = self.controlsHidden ? 0 : 1 }
        if animated && !UIAccessibility.isReduceMotionEnabled { UIView.animate(withDuration: 0.2, animations: changes) }
        else { changes() }
        updateGestures()
    }
}
