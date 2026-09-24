import UIKit

/// 在首批数据与自适应布局稳定后展示时间线，避免暴露初始底部定位过程。
@MainActor
final class ConversationInitialPresentation: NSObject {
    private weak var collectionView: UICollectionView?
    private let indicator = UIActivityIndicatorView(style: .medium)
    private var displayLink: CADisplayLink?
    private var waitsForHistory = false
    private var hasAppliedSnapshot = false
    private var previousGeometry: Geometry?
    private(set) var isPresented = false

    private struct Geometry: Equatable {
        let size: CGSize
        let bounds: CGRect
        let insets: UIEdgeInsets
    }

    init(collectionView: UICollectionView) {
        self.collectionView = collectionView
        super.init()
        collectionView.alpha = 0
        collectionView.accessibilityElementsHidden = true
    }

    isolated deinit { displayLink?.invalidate() }

    func waitForHistory(in host: UIView) {
        guard !isPresented else { return }
        waitsForHistory = true
        host.addSubview(indicator)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        indicator.startAnimating()
    }

    /// 加载失败或空结果同样必须解除等待；发送消息时也立即进入展示流程。
    func finishWaitingForHistory() {
        waitsForHistory = false
        resumeIfNeeded()
    }

    func willApplySnapshot() {
        guard !isPresented else { return }
        hasAppliedSnapshot = false
        previousGeometry = nil
    }

    func didApplySnapshot() {
        hasAppliedSnapshot = true
        resumeIfNeeded()
    }

    /// 离开窗口即停止采样；重新挂载时继续尚未完成的首次定位。
    func resumeIfNeeded() {
        guard !isPresented, let collectionView, collectionView.window != nil else {
            stopSampling()
            return
        }
        guard !waitsForHistory, hasAppliedSnapshot, displayLink == nil else { return }
        let link = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.tick))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func stopSampling() {
        displayLink?.invalidate()
        displayLink = nil
        previousGeometry = nil
    }

    private func positionBeforeDisplay() {
        guard !isPresented, !waitsForHistory, hasAppliedSnapshot,
              let list = collectionView, list.window != nil,
              list.bounds.width > 0, list.bounds.height > 0 else { return }
        UIView.performWithoutAnimation {
            list.layoutIfNeeded()
            let section = list.numberOfSections - 1
            if section >= 0, list.numberOfItems(inSection: section) > 0 {
                list.scrollToItem(at: IndexPath(item: list.numberOfItems(inSection: section) - 1,
                                               section: section), at: .bottom, animated: false)
                list.layoutIfNeeded()
            }
            // 同时计入分区尾部留白与安全区；短列表保持正常顶部起点。
            let bottom = max(-list.adjustedContentInset.top,
                             list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
            list.setContentOffset(CGPoint(x: list.contentOffset.x, y: bottom), animated: false)
            list.layoutIfNeeded()
            let geometry = Geometry(size: list.contentSize, bounds: list.bounds,
                                    insets: list.adjustedContentInset)
            // 连续两次屏幕刷新前布局一致，才允许首帧消息进入可见状态。
            guard geometry == previousGeometry,
                  abs(list.contentOffset.y - max(-list.adjustedContentInset.top,
                      list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)) < 1 else {
                previousGeometry = geometry
                return
            }
            isPresented = true
            list.alpha = 1
            list.accessibilityElementsHidden = false
            indicator.stopAnimating()
            indicator.removeFromSuperview()
            stopSampling()
        }
    }

    /// CADisplayLink 不持有页面，页面提前释放时无需等待下一帧打破循环引用。
    @MainActor
    private final class WeakTarget: NSObject {
        weak var owner: ConversationInitialPresentation?
        init(_ owner: ConversationInitialPresentation) { self.owner = owner }
        @objc func tick() { owner?.positionBeforeDisplay() }
    }
}
