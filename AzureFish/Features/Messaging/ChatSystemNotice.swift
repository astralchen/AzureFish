import AzureFishAPI

/// 按当前账号解释系统事件，不把服务端类型或身份展示给用户。
@MainActor
enum ChatSystemNotice {
    static func text(_ message: ChatMessage, userID: String) -> String {
        guard message.kind == "system", message.schemaVersion == 1,
              let event = message.systemEvent, event.kind == "friendship_accepted" else {
            return Localization.text("chat.system.unknown")
        }
        return Localization.text(event.accepterID == userID
            ? "chat.system.friendshipAcceptedSelf" : "chat.system.friendshipAcceptedOther")
    }
}
