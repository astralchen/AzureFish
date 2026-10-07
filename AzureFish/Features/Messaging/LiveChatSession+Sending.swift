import AzureFishAPI
import AzureFishChat
import UniformTypeIdentifiers
import UIKit

@available(iOS 26.0, *)
extension LiveChatSession {
    func send(_ values: [MessageContent], completion: @escaping (Bool) -> Void) {
        guard !stopped, runtime.canSend(conversation), let engine = runtime.engine,
              let media = runtime.media, let drafts = runtime.originalDraftStore,
              let manager = runtime.session.sessionManager, let controller else { completion(false); return }
        contextAnchor = nil
        let release = (controller.attachmentStore as? PageAttachmentStore)?.acquireFileLease()
        let task = drafts.enqueue { [self] in
            let wasLocal = ChatStore.localDirectPeer(conversation.id) != nil
            conversation = try await runtime.resolveDirectConversationForSending(conversation)
            let conversationID = conversation.id
            if wasLocal {
                installConversationDetails()
                loadHistory()
            }
            let credentials = try await manager.localIdentity()
            guard runtime.engine === engine, credentials.userID == engine.store.userID else { throw ChatStoreError.scopeMismatch }
            let importBatch = try await engine.store.beginMediaImport()
            do {
            var saved: [String: StoredChatDraft] = [:]
            var items: [ChatCompositionItem] = []
            var presentations: [String: MessageContent] = [:]
            for content in values {
                try Task.checkCancellation()
                let outgoing: ChatOutgoing
                switch content {
                case .localized: throw APIClientError.invalidRequest
                case .userText(let text):
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    outgoing = .init(conversationID: conversationID, deviceID: credentials.deviceID, text: text)
                case .richText(let text):
                    guard !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    outgoing = .init(conversationID: conversationID, deviceID: credentials.deviceID, text: text.text,
                        textRuns: text.runs.map { .init(text: $0.text, style: UInt32($0.style.rawValue)) })
                case .attachment(.link(let link)):
                    guard LinkAttachment.accepts(link.url) else { throw APIClientError.invalidRequest }
                    outgoing = .init(conversationID: conversationID, deviceID: credentials.deviceID, kind: "link",
                        text: link.url.absoluteString, linkURL: link.url.absoluteString)
                case .attachment(let attachment):
                    let uploaded = try await uploadItems(attachment, media: media, batch: importBatch, store: engine.store)
                    let kind: String = switch attachment { case .audio: "audio"; case .file: "file"; default: "media_group" }
                    let batch = ChatUploadBatch(conversation: conversationID, kind: kind, items: uploaded, deviceID: credentials.deviceID)
                    let key = batch.messageID.uuidString.lowercased()
                    var snapshot = ChatDraftSnapshot(conversationID: conversationID)
                    snapshot.documents = [attachment]
                    saved[key] = try await drafts.encrypt(snapshot, batch: importBatch).storageValue()
                    items.append(.upload(batch)); presentations[key] = content
                    continue
                }
                guard outgoing.text.count <= 16384, outgoing.text.utf8.count <= 65536 else { throw APIClientError.requestTooLarge }
                items.append(.message(outgoing))
                let key = outgoing.id.uuidString.lowercased()
                presentations[key] = content
                if case .attachment(let attachment) = content {
                    var snapshot = ChatDraftSnapshot(conversationID: conversationID)
                    snapshot.documents = [attachment]
                    saved[key] = try await drafts.encrypt(snapshot, batch: importBatch).storageValue()
                }
            }
            guard runtime.engine === engine, runtime.canSend(conversation) else { throw ChatStoreError.unavailable }
            try await engine.store.enqueueComposition(items, conversation: conversationID, presentations: saved, completingImport: importBatch)
            return presentations
            } catch {
                try? await engine.store.cancelMediaImport(importBatch)
                try? await engine.store.cleanupMedia(using: media)
                throw error
            }
        }
        Task { [weak self] in
            defer { release?() }
            do {
                let presentations = try await task.value
                guard let self, runtime.engine === engine else { return }
                if !stopped {
                    contents.merge(presentations) { _, new in new }
                    pendingReason = .sentMessage
                    completion(true)
                    refresh()
                }
                await engine.changed()
                await runtime.transfers?.resume()
                await engine.flush()
            } catch { completion(false) }
        }
    }
    func cache(_ attachment: Attachment, key: String, drafts: AccountChatDraftStore) async throws {
        var snapshot = ChatDraftSnapshot(conversationID: conversation.id)
        snapshot.documents = [attachment]
        let batch = try await drafts.store.beginMediaImport()
        do {
            let encrypted = try await drafts.encrypt(snapshot, batch: batch)
            try await drafts.store.savePresentation(encrypted.storageValue(), message: key, completingImport: batch)
        } catch {
            try? await drafts.store.cancelMediaImport(batch)
            try? await drafts.store.cleanupMedia(using: drafts.media)
            throw error
        }
    }
    func uploadItems(_ attachment: Attachment, media: ChatMediaStore, batch: UUID, store: ChatStore) async throws -> [ChatUploadItem] {
        func resource(_ url: URL, name: String? = nil, role: String = "original") async throws -> ChatLocalMedia {
            try await store.importMedia(url, filename: name ?? url.lastPathComponent,
                mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", role: role, using: media, batch: batch)
        }
        switch attachment {
        case .file(let file): return [.init(kind: "file", resources: [try await resource(file.fileURL, name: file.displayName)])]
        case .audio(let audio): return [.init(kind: "audio", resources: [try await resource(audio.fileURL)])]
        case .mediaGroup(let group):
            guard !group.items.isEmpty, group.items.count <= 20 else { throw APIClientError.invalidRequest }
            var items: [ChatUploadItem] = []
            for item in group.items {
                var resources = [try await resource(item.originalFileURL)]
                if let paired = item.livePhotoVideoURL { resources.append(try await resource(paired, role: "paired_video")) }
                items.append(.init(kind: item.isLivePhoto ? "live_photo" : item.kind.isVideo ? "video" : "image", resources: resources))
            }
            return items
        case .remote: throw APIClientError.invalidRequest
        case .link: throw APIClientError.invalidRequest
        }
    }
    func retry(_ messageID: Int) {
        guard let key = sourceIDs[messageID] else { return }
        if let value = pending.first(where: { $0.outgoing.id.uuidString.lowercased() == key }) {
            perform { [self] in try await runtime.engine?.retry(value); refresh() }
        } else if let value = uploads.first(where: { $0.messageID.uuidString.lowercased() == key }) {
            perform { [self] in try await runtime.transfers?.retry(value.id); refresh() }
        } else { mediaFailures.remove(key); scheduleMedia() }
    }
    func delete(_ messageID: Int) {
        guard let key = sourceIDs[messageID] else { return }
        perform { [self] in
            if let batch = uploads.first(where: { $0.messageID.uuidString.lowercased() == key }) {
                try await runtime.transfers?.cancel(batch.id)
                try await runtime.engine?.store.hide(message: key)
            } else {
                try await runtime.engine?.store.hide(message: key)
                try await runtime.engine?.store.removePending(message: key)
            }
            evict(key)
            await runtime.engine?.changed()
            await runtime.engine?.flush()
            refresh()
        }
    }
    func revoke(_ messageID: Int) {
        guard let key = sourceIDs[messageID], let message = messages.first(where: { $0.id == key }),
              message.senderID == runtime.userID, !message.revoked, let engine = runtime.engine else { return }
        let id = revokeIDs[key] ?? UUID(); revokeIDs[key] = id
        perform { [self] in
            let result = try await engine.revoke(message, fallbackOperationID: id)
            guard !stopped, runtime.engine === engine else { return }
            if let index = messages.firstIndex(where: { $0.id == key }) { messages[index] = result.message }
            evict(key)
            refresh()
        }
    }
    func reedit(_ messageID: Int) {
        guard let key = sourceIDs[messageID], let controller, !controller.isRestoringDraft,
              !controller.isSubmittingComposition, runtime.canSend(conversation), controller.presentedViewController == nil,
              let drafts = runtime.originalDraftStore, let engine = runtime.engine else { return }
        let snapshot = controller.makeDraftSnapshot()
        let restore = { [weak self, weak controller] in
            guard let self, let controller, !stopped else { return }
            controller.flushDraftBeforeLeaving()
            controller.isSubmittingComposition = true
            perform { [self, weak controller] in
                defer {
                    controller?.isSubmittingComposition = false
                    refresh()
                }
                let text = try await engine.store.reeditText(message: key, conversation: conversation.id)
                let runs = try await engine.store.reeditRuns(message: key, conversation: conversation.id)
                guard let controller, !stopped, runtime.canSend(conversation), controller.makeDraftSnapshot() == snapshot else { throw ChatStoreError.draftChanged }
                var updated = snapshot
                let replacement: DraftSegment = runs.isEmpty ? .text(text) : .richText(.init(runs: runs.map { .init($0.text, style: .init(rawValue: Int($0.style))) }))
                updated.segments = [replacement] + snapshot.segments.filter { if case .attachment = $0 { return true }; return false }
                try await drafts.saveReedited(updated, message: key, original: text).value
                guard !stopped else { return }
                controller.isRestoringDraft = true
                controller.composerView.restoreDraft(segments: updated.segments, documents: controller.documentController.drafts)
                controller.isRestoringDraft = false
                controller.draftCoordinator?.restored(updated)
                controller.composerView.textView.becomeFirstResponder()
                controller.layoutChatContent()
            }
        }
        if snapshot.segments.contains(where: { switch $0 { case .text(let text): !text.isEmpty; case .richText(let text): !text.text.isEmpty; case .attachment: false } }) {
            let alert = UIAlertController(title: Localization.text("chat.live.replaceDraftTitle"), message: Localization.text("chat.live.replaceDraftBody"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: Localization.text("imessage.action.cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: Localization.text("chat.live.replaceDraft"), style: .destructive) { _ in restore() })
            controller.present(alert, animated: true)
        } else { restore() }
    }
}
