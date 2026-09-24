import AppLocalization
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatMessageMenuTests {
    @Test(arguments: [MessageDirection.incoming, .outgoing], [MessageDeliveryState.sending, .delivered, .read, .failed])
    func textMenuMatchesDirectionAndState(direction: MessageDirection, state: MessageDeliveryState) {
        let message = MessagePresentation(id: 7, direction: direction, text: "Hello", deliveryText: nil, deliveryState: state)
        let items = MessageMenuPolicy.items(for: message, target: .init(messageID: 7))
        let retry: [MessageMenuOperation] = direction == .outgoing && state == .failed ? [.retry] : []
        #expect(items.map(\.operation) == [.copy, .selectText, .share] + retry + [.delete])
        #expect(MessageMenuPolicy.items(for: message, target: .init(messageID: 8)).isEmpty)
    }

    @Test func mediaTargetsUseItemIdentityAndMenusDistinguishFormats() throws {
        let url = URL(fileURLWithPath: "/tmp/menu.jpg")
        let kinds: [(MediaKind, Bool, URL?, String, Bool)] = [
            (.image, false, nil, "savePhoto", true), (.image, true, nil, "saveGIF", true),
            (.image, false, url, "saveLivePhoto", true), (.video(duration: 2), false, nil, "saveVideo", false)
        ]
        let group = MediaGroupAttachment(items: kinds.map { kind, animated, paired, _, _ in
            MediaItem(assetIdentifier: nil, originalFileURL: url, thumbnailFileURL: url,
                      pixelSize: .init(width: 30, height: 40), kind: kind, isAnimatedImage: animated, livePhotoVideoURL: paired)
        })
        let message = MessagePresentation(id: 8, direction: .outgoing, attachment: .mediaGroup(group), deliveryText: nil)
        for (index, kind) in kinds.enumerated() {
            let target = MessageMenuTarget(messageID: 8, attachmentID: group.id, mediaItemID: group.items[index].id)
            let items = MessageMenuPolicy.items(for: message, target: target)
            #expect(items.contains { $0.operation == .copy } == kind.4)
            #expect(items.first { $0.operation == .save }?.titleKey == "imessage.menu." + kind.3)
            #expect(items.last?.operation == .delete)
            #expect(target.attachment(in: message)?.mediaGroup?.items == [group.items[index]])
            let saving = MessageMenuPolicy.items(for: message, target: target, saveState: .saving)
            #expect(saving.first { $0.operation == .save }?.isEnabled == false)
            #expect(saving.first { $0.operation == .share }?.titleKey == (index == 2 ? "imessage.menu.shareOriginals" : "imessage.menu.share"))
        }
        #expect(!MessageMenuTarget(messageID: 8, attachmentID: group.id, mediaItemID: UUID()).matches(message))
        #expect(!MessageMenuTarget(messageID: 8, attachmentID: UUID(), mediaItemID: group.items[0].id).matches(message))
    }

    @Test func fileLinkAndAudioMenusReflectContent() {
        let url = URL(fileURLWithPath: "/tmp/audio.m4a")
        for transcript: String? in [nil, "", "spoken words"] {
            let attachment = AzureFish.Attachment.audio(.init(fileURL: url, duration: 2, waveform: [], transcript: transcript))
            let message = MessagePresentation(id: 1, direction: .incoming, attachment: attachment, deliveryText: nil)
            let operations = MessageMenuPolicy.items(for: message, target: .init(messageID: 1, attachmentID: attachment.id)).map(\.operation)
            #expect(operations == (transcript == "spoken words" ? [.copy, .save, .share, .delete] : [.save, .share, .delete]))
            #expect(AttachmentSavePolicy.supports(attachment))
            #expect(!AttachmentSavePolicy.showsButton(for: message))
        }
        let link = AzureFish.Attachment.link(.init(url: URL(string: "https://www.apple.com")!))
        let message = MessagePresentation(id: 1, direction: .incoming, attachment: link, deliveryText: nil)
        #expect(MessageMenuPolicy.items(for: message, target: .init(messageID: 1, attachmentID: link.id)).map(\.operation)
                == [.openLink, .copy, .share, .delete])
        let file = AzureFish.Attachment.file(.init(id: UUID(), fileURL: url, displayName: "audio.m4a", typeIdentifier: "public.audio", byteCount: 1))
        let document = MessagePresentation(id: 1, direction: .outgoing, attachment: file, deliveryText: nil)
        #expect(MessageMenuPolicy.items(for: document, target: .init(messageID: 1, attachmentID: file.id)).map(\.operation)
                == [.save, .share, .delete])
    }

    @Test func richTextClipboardRetainsTextAndFormatting() async throws {
        let rich = MessageText(runs: [.init("Bold", style: .bold), .init("\nPlain")])
        let message = MessagePresentation(id: 1, direction: .incoming, richText: rich, deliveryText: nil)
        let items = try await MessageClipboard.representations(for: message, target: .init(messageID: 1))
        #expect(String(data: try #require(items[UTType.utf8PlainText.identifier]), encoding: .utf8) == rich.text)
        let rtf = try NSAttributedString(data: #require(items[UTType.rtf.identifier]), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(rtf.string == rich.text)
        #expect((rtf.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }

    @Test func gifCopyUsesOriginalBytesAndExportSurvivesSourceRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("animation.gif")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let image = renderer.image { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        for _ in 0..<2 { CGImageDestinationAddImage(destination, try #require(image.cgImage), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary) }
        #expect(CGImageDestinationFinalize(destination))
        let media = MediaItem(assetIdentifier: nil, originalFileURL: url, thumbnailFileURL: url, pixelSize: .init(width: 4, height: 4), kind: .image, isAnimatedImage: true)
        let group = MediaGroupAttachment(items: [media])
        let message = MessagePresentation(id: 1, direction: .incoming, attachment: .mediaGroup(group), deliveryText: nil)
        let target = MessageMenuTarget(messageID: 1, attachmentID: group.id, mediaItemID: media.id)
        let copied = try await MessageClipboard.representations(for: message, target: target)
        #expect(copied[UTType.gif.identifier] == (try Data(contentsOf: url)))
        var snapshot: AttachmentSaveSnapshot? = try AttachmentSaveSnapshot(.mediaGroup(group))
        let exported = try #require(snapshot?.files.first)
        try FileManager.default.removeItem(at: url)
        #expect(FileManager.default.isReadableFile(atPath: exported.path))
        snapshot = nil
        #expect(!FileManager.default.fileExists(atPath: exported.path))
    }

    @Test func livePhotoSnapshotRequiresBothResourcesAndAudioExports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("photo.jpg"), video = directory.appendingPathComponent("paired.mov")
        try Data([1, 2]).write(to: photo)
        try Data([3, 4]).write(to: video)
        let group = MediaGroupAttachment(items: [.init(assetIdentifier: nil, originalFileURL: photo, thumbnailFileURL: photo,
            pixelSize: .init(width: 10, height: 10), kind: .image, livePhotoVideoURL: video)])
        let snapshot = try AttachmentSaveSnapshot(.mediaGroup(group))
        #expect(try Data(contentsOf: #require(snapshot.pairedVideos.first ?? nil)) == Data([3, 4]))
        try FileManager.default.removeItem(at: video)
        #expect(throws: (any Error).self) { try AttachmentSaveSnapshot(.mediaGroup(group)) }
        let audio = AzureFish.Attachment.audio(.init(fileURL: photo, duration: 2, waveform: []))
        let exported = try AttachmentSaveSnapshot(audio)
        #expect(exported.files.count == 1)
        #expect(exported.pairedVideos == [nil])
    }

    @Test func menuSavingDeduplicatesOnlyTheSameTarget() async throws {
        let saver = MenuTestSaver()
        let coordinator = MessageMenuSaveCoordinator(saver: saver)
        let attachment = AzureFish.Attachment.audio(.init(fileURL: URL(fileURLWithPath: "/tmp/audio.caf"), duration: 2, waveform: []))
        let message = MessagePresentation(id: 1, direction: .outgoing, attachment: attachment, deliveryText: nil)
        let target = MessageMenuTarget(messageID: 1, attachmentID: attachment.id)
        coordinator.save(target, message: message, from: UIViewController())
        coordinator.save(target, message: message, from: UIViewController())
        for _ in 0..<100 where saver.calls == 0 { await Task.yield() }
        #expect(saver.calls == 1)
        #expect(coordinator.isSaving(target))
        saver.finish()
        for _ in 0..<100 where coordinator.isSaving(target) { await Task.yield() }
        #expect(!coordinator.isSaving(target))
        coordinator.save(target, message: message, from: UIViewController())
        for _ in 0..<100 where saver.calls < 2 { await Task.yield() }
        #expect(saver.calls == 2)
        saver.finish()
    }
}

@MainActor private final class MenuTestSaver: AttachmentSaving {
    var calls = 0
    var continuation: CheckedContinuation<AttachmentSaveOutcome, Never>?
    func save(_ attachment: AzureFish.Attachment, from presenter: UIViewController) async throws -> AttachmentSaveOutcome {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: .cancelled); continuation = nil }
}
