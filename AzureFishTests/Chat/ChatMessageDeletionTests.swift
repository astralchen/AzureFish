import AppLocalization
import AVFAudio
import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatMessageDeletionTests {
    @Test func deleteStopsSelectedPlaybackPreservesSharedFileAndRejectsTranscript() async throws {
        guard #available(iOS 26.0, *) else { return }
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let directory = try #require(Bundle.main.url(forResource: "AttachmentPreviewResources", withExtension: "bundle"))
        let url = try store.importFile(at: directory.appendingPathComponent("default-message.caf"), prefix: "menu-audio", pathExtension: nil)
        let attachment = AudioAttachment(fileURL: url, duration: 8, waveform: [0.2, 0.5], transcript: "Audio")
        let reply = try #require(AzureFish.Attachment.audio(attachment).simulatedReply().audio)
        let model = ChatViewModel(localizer: Localizer { key, _ in key }, clock: Date.init, sleeper: { try await Task.sleep(for: $0) })
        model.insertInitialHistory([
            .init(direction: .incoming, content: .attachment(.audio(attachment))),
            .init(direction: .outgoing, content: .attachment(.audio(reply)))
        ])
        let audio = AudioController(attachmentStore: store)
        let controller = ChatViewController(viewModel: model, audioController: audio)
        controller.loadViewIfNeeded()
        defer { audio.stopAll(); controller.audioTranscription.cancelAll(); model.cancelPendingReply() }
        audio.toggleMessagePlayback(messageID: 0, attachment: attachment)
        #expect(await eventually { audio.playbackState.isPlaying })
        #expect(audio.player?.isPlaying == true)
        controller.deleteMenuMessage(.init(messageID: 1, attachmentID: reply.id))
        #expect(audio.playbackState.messageID == 0)
        #expect(audio.player?.isPlaying == true)
        controller.deleteMenuMessage(.init(messageID: 0, attachmentID: attachment.id))
        #expect(audio.playbackState == .idle)
        #expect(audio.player == nil)
        #expect(FileManager.default.isReadableFile(atPath: url.path))
        #expect(!model.updateAudioTranscript("late", messageID: 0, attachmentID: attachment.id))
        #expect(model.state.timeline.isEmpty)
    }

    @Test func deletionKeepsReadingAnchorWhenRowsAboveOrAnchorAreRemoved() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        let host = UIViewController()
        let conversation = ConversationView(frame: window.bounds)
        host.view = conversation
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; oldWindow?.makeKeyAndVisible() }
        var messages = (0..<50).map { MessagePresentation(id: $0, direction: .incoming, text: "Message \($0)\nSecond line", deliveryText: nil) }
        func state() -> ChatViewModel.State {
            .init(timeline: messages.map { .init(id: .message($0.id), content: .message($0)) }, isTyping: false)
        }
        conversation.render(state(), reason: .initial)
        #expect(await eventually { conversation.collectionView.alpha == 1 && conversation.collectionView.numberOfItems(inSection: 0) == 50 && conversation.collectionView.indexPathsForVisibleItems.contains(IndexPath(item: 49, section: 0)) })
        conversation.collectionView.layoutIfNeeded()
        conversation.collectionView.scrollToItem(at: IndexPath(item: 20, section: 0), at: .top, animated: false)
        conversation.collectionView.layoutIfNeeded()
        let anchor = try #require(conversation.collectionView.captureLocalizationAnchor())
        let anchorID = messages[anchor.indexPath.item].id
        messages.removeFirst()
        conversation.render(state(), reason: .messageDeleted)
        #expect(await eventually {
            guard conversation.collectionView.numberOfItems(inSection: 0) == 49,
                  let restored = conversation.collectionView.captureLocalizationAnchor(),
                  messages.indices.contains(restored.indexPath.item) else { return false }
            return messages[restored.indexPath.item].id == anchorID
                && abs(restored.offsetFromViewportTop - anchor.offsetFromViewportTop) < 1
        })
        conversation.collectionView.layoutIfNeeded()
        let after = try #require(conversation.collectionView.captureLocalizationAnchor())
        #expect(messages[after.indexPath.item].id == anchorID)
        #expect(abs(after.offsetFromViewportTop - anchor.offsetFromViewportTop) < 1)
        // 删除当前锚点仍停留在相邻消息附近，不跳到底部。
        messages.removeAll { $0.id == anchorID }
        conversation.render(state(), reason: .messageDeleted)
        #expect(await eventually { conversation.collectionView.numberOfItems(inSection: 0) == 48 })
        conversation.collectionView.layoutIfNeeded()
        let neighboring = try #require(conversation.collectionView.captureLocalizationAnchor())
        #expect(abs(messages[neighboring.indexPath.item].id - anchorID) <= 2)
        #expect(!conversation.isNearBottom)
    }

    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
