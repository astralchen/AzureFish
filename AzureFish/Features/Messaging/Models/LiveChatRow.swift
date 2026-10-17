struct LiveChatRow: Sendable, Equatable {
    let id: String
    let title: String
    var subtitle: String = ""
    var symbol: String = "person.crop.circle.fill"
    var badge: String = ""
    var markers: [String] = []
    var highlight: String? = nil
    var isPinned = false
    var manuallyUnread = false
    var isDraft = false
    var avatarUser: String? = nil
    var avatarAsset: String? = nil
    var timeText: String = ""
    var timeAccessibilityText: String = ""
}
