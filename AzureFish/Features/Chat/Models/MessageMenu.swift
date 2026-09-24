import Foundation

/// 菜单打开时锁定内容身份，不保存可能变化的 Cell 或媒体索引。
nonisolated struct MessageMenuTarget: Hashable, Sendable {
    let messageID: Int
    var attachmentID: UUID? = nil
    var mediaItemID: UUID? = nil

    func matches(_ message: MessagePresentation) -> Bool {
        guard message.id == messageID else { return false }
        switch message.content {
        case .text, .richText: return attachmentID == nil && mediaItemID == nil
        case .attachment(let attachment):
            guard attachment.id == attachmentID else { return false }
            if case .mediaGroup(let group) = attachment {
                return group.items.contains { $0.id == mediaItemID }
            }
            return mediaItemID == nil
        }
    }

    /// 保留附件身份，将媒体操作收窄到锁定的单项。
    func attachment(in message: MessagePresentation) -> Attachment? {
        guard matches(message), case .attachment(let attachment) = message.content else { return nil }
        if case .mediaGroup(let group) = attachment,
           let item = group.items.first(where: { $0.id == mediaItemID }) {
            return .mediaGroup(.init(id: group.id, items: [item]))
        }
        return attachment
    }
}

nonisolated enum MessageMenuOperation: String, Equatable, Sendable {
    case copy, selectText, share, save, openLink, retry, delete
}

nonisolated struct MessageMenuItem: Equatable, Sendable {
    let operation: MessageMenuOperation
    let titleKey: String
    let symbol: String
    var isEnabled = true
}

/// 内容能力与气泡旁保存按钮的显示策略相互独立。
nonisolated enum MessageMenuPolicy {
    static func items(for message: MessagePresentation, target: MessageMenuTarget,
                      saveState: AttachmentSaveState = .available) -> [MessageMenuItem] {
        guard target.matches(message) else { return [] }
        var items: [MessageMenuItem] = []
        func append(_ operation: MessageMenuOperation, _ key: String, _ symbol: String) {
            items.append(.init(operation: operation, titleKey: "imessage.menu." + key, symbol: symbol))
        }
        switch message.content {
        case .text, .richText:
            append(.copy, "copy", "doc.on.doc")
            append(.selectText, "selectText", "character.cursor.ibeam")
        case .attachment:
            guard let attachment = target.attachment(in: message) else { return [] }
            switch attachment {
            case .link:
                append(.openLink, "openLink", "safari")
                append(.copy, "copyLink", "link")
            case .audio(let audio):
                if audio.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    append(.copy, "copyTranscript", "doc.on.doc")
                }
                append(.save, "saveFiles", "square.and.arrow.down")
            case .file:
                append(.save, "saveFiles", "square.and.arrow.down")
            case .mediaGroup(let group):
                guard let item = group.items.first else { return [] }
                if !item.kind.isVideo {
                    append(.copy, item.isLivePhoto ? "copyStill" : "copy", "doc.on.doc")
                }
                let key = item.kind.isVideo ? "saveVideo" : item.isLivePhoto ? "saveLivePhoto"
                    : item.isAnimatedImage ? "saveGIF" : "savePhoto"
                append(.save, key, "square.and.arrow.down")
            }
        }
        let live = target.attachment(in: message)?.mediaGroup?.items.first?.isLivePhoto == true
        append(.share, live ? "shareOriginals" : "share", "square.and.arrow.up")
        if message.direction == .outgoing && message.deliveryState == .failed {
            append(.retry, "retry", "arrow.clockwise")
        }
        append(.delete, "delete", "trash")
        if saveState == .saving || saveState == .completed, let index = items.firstIndex(where: { $0.operation == .save }) {
            items[index] = .init(operation: .save, titleKey: saveState == .completed ? "imessage.save.completed" : "imessage.menu.saving",
                                 symbol: saveState == .completed ? "checkmark" : "square.and.arrow.down", isEnabled: false)
        }
        return items
    }
}
