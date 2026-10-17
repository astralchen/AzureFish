import AppLocalization
import AzureFishAPI
import AzureFishChat
import UIKit

/// 两种聊天页面共用详情导航，连续点击不会重复入栈。
@MainActor
enum ConversationDetailsNavigation {
    static func install(on controller: UIViewController, runtime: ChatRuntime,
                        conversation: @escaping () -> ChatConversation,
                        locate: @escaping (ChatMessage) async throws -> Void) {
        let button = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), primaryAction: UIAction { [weak controller] _ in
            guard let controller, let navigation = controller.navigationController,
                  navigation.topViewController === controller, navigation.transitionCoordinator == nil else { return }
            let page = ConversationDetailsViewController(runtime: runtime, conversation: conversation()) { [weak controller] message in
                guard let controller, let navigation = controller.navigationController else { throw ChatStoreError.unavailable }
                try await locate(message)
                navigation.popToViewController(controller, animated: true)
            }
            navigation.pushViewController(page, animated: true)
        })
        button.accessibilityIdentifier = "chat.details.open"
        button.accessibilityLabel = Localization.text("chat.live.details")
        controller.navigationItem.rightBarButtonItem = button
    }
}
