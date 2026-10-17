import UIKit

/// 场景窗口记录实际触摸，不改变事件分发或当前输入焦点。
final class ChatInteractionWindow: UIWindow {
    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches, event.allTouches?.contains(where: { $0.phase == .began }) == true,
           let windowScene { ChatIncomingBannerCoordinator.interacted(with: windowScene) }
        super.sendEvent(event)
    }
}
