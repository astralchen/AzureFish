import AppLocalization
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 为剪贴板提供独立数据，页面退出后仍可粘贴；媒体读取不占用主线程。
@MainActor
enum MessageClipboard {
    static func representations(for message: MessagePresentation, target: MessageMenuTarget) async throws -> [String: Data] {
        guard target.matches(message) else { throw AttachmentSaveError.invalidAttachment }
        switch message.content {
        case .text(let text):
            return [UTType.utf8PlainText.identifier: Data(text.utf8)]
        case .richText(let text):
            let attributed = text.attributedString(font: .preferredFont(forTextStyle: .body), color: .label)
            let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            return [UTType.utf8PlainText.identifier: Data(text.text.utf8), UTType.rtf.identifier: rtf]
        case .attachment:
            switch target.attachment(in: message) {
            case .link(let link):
                return [UTType.url.identifier: Data(link.url.absoluteString.utf8),
                        UTType.utf8PlainText.identifier: Data(link.url.absoluteString.utf8)]
            case .audio(let audio):
                guard let text = audio.transcript, !text.isEmpty else { throw AttachmentSaveError.invalidAttachment }
                return [UTType.utf8PlainText.identifier: Data(text.utf8)]
            case .mediaGroup(let group):
                guard let item = group.items.first, !item.kind.isVideo else { throw AttachmentSaveError.invalidAttachment }
                let url = item.originalFileURL
                return try await Task.detached(priority: .userInitiated) {
                    let data = try Data(contentsOf: url)
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let type = CGImageSourceGetType(source) else { throw AttachmentSaveError.invalidAttachment }
                    return [type as String: data]
                }.value
            default: throw AttachmentSaveError.invalidAttachment
            }
        }
    }
}

/// 菜单的单项保存独立于整组快捷按钮；完成反馈后可以再次保存。
@MainActor
final class MessageMenuSaveCoordinator {
    private let saver: any AttachmentSaving
    private var states: [MessageMenuTarget: AttachmentSaveState] = [:]
    private var active = true
    var failed: ((Error) -> Void)?
    var changed: (() -> Void)?

    init(saver: any AttachmentSaving = SystemAttachmentSaver()) { self.saver = saver }
    func state(for target: MessageMenuTarget) -> AttachmentSaveState { states[target] ?? .available }
    func isSaving(_ target: MessageMenuTarget) -> Bool { state(for: target) == .saving || state(for: target) == .completed }

    func save(_ target: MessageMenuTarget, message: MessagePresentation, from presenter: UIViewController) {
        guard active, let attachment = target.attachment(in: message), AttachmentSavePolicy.supports(attachment),
              !isSaving(target) else { return }
        states[target] = .saving
        changed?()
        let saver = saver
        Task { [weak self] in
            guard self?.active == true else { return }
            do {
                let outcome = try await saver.save(attachment, from: presenter)
                if case .saved = outcome, self?.active == true {
                    self?.states[target] = .completed
                    self?.changed?()
                    UIAccessibility.post(notification: .announcement, argument: Localization.text("imessage.save.completed"))
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            } catch {
                if self?.active == true { self?.failed?(error) }
            }
            self?.states[target] = nil
            if self?.active == true { self?.changed?() }
        }
    }

    func invalidate() {
        active = false
        failed = nil
        changed = nil
    }
}
