import AzureFishAPI
import AzureFishChat
import Foundation

/// 原版编辑器的账号草稿适配器；快照在 SQLCipher 中保存，资源只引用加密媒体身份。
@MainActor
final class AccountChatDraftStore: ChatDraftStoring {
    let store: ChatStore
    let media: ChatMediaStore
    private var tail: Task<Void, Never>?
    var legacyLoaders: [URL: ([ChatUploadItem]) async throws -> [Attachment]] = [:]
    private var imported: [URL: (Date?, Int64, UUID)] = [:]
    init(store: ChatStore, media: ChatMediaStore) { self.store = store; self.media = media }

    /// 所有页面共用该顺序链，离开后立即重进也不会读到更早的保存结果。
    func enqueue<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) -> Task<T, Error> {
        let previous = tail
        let task = Task { await previous?.value; return try await work() }
        tail = Task { _ = await task.result }
        return task
    }
    func load(conversationID: String, into directory: URL) -> Task<ChatDraftLoadResult, Error> {
        enqueue { [self] in
            if let snapshot: ChatDraftSnapshot = try await store.meta("rich-draft:" + conversationID) {
                guard snapshot.version == 1, snapshot.conversationID == conversationID else { throw ChatStoreError.scopeMismatch }
                return try await materialize(snapshot, into: directory)
            }
            let old = try await store.draft(conversationID)
            var snapshot = ChatDraftSnapshot(conversationID: conversationID)
            if !old.text.isEmpty { snapshot.segments = [.text(old.text)] }
            var missing = false
            if let items: [ChatUploadItem] = try await store.meta("attachments:" + conversationID), !items.isEmpty {
                if let loader = legacyLoaders[directory] {
                    do {
                        snapshot.documents = try await loader(items)
                        snapshot.segments += snapshot.documents.map { .attachment($0.id) }
                    } catch { missing = true }
                } else { missing = true }
            }
            return ChatDraftLoadResult(snapshot: snapshot.isEmpty ? nil : snapshot, hasMissingAttachments: missing)
        }
    }
    func save(_ snapshot: ChatDraftSnapshot) -> Task<Void, Error> {
        enqueue { [self] in
            let value = try await encrypt(snapshot)
            let text = snapshot.segments.map { segment -> String in
                switch segment { case .text(let text): text; case .richText(let text): text.text; case .attachment: "" }
            }.joined()
            try await store.saveEditorDraft(value, text: text, conversation: snapshot.conversationID)
        }
    }
    func saveReedited(_ snapshot: ChatDraftSnapshot, message: String, original: String) -> Task<Void, Error> {
        enqueue { [self] in
            let value = try await encrypt(snapshot)
            try await store.saveEditorDraft(value, text: original, conversation: snapshot.conversationID,
                reediting: message, expectedText: original)
        }
    }
    func remove(conversationID: String) -> Task<Void, Error> {
        enqueue { [self] in
            try await store.saveEditorDraft(ChatDraftSnapshot(conversationID: conversationID), text: "", conversation: conversationID)
        }
    }
    func encrypt(_ snapshot: ChatDraftSnapshot, reuseResources: Bool = true) async throws -> ChatDraftSnapshot {
        var replacements: [URL: URL] = [:]
        for url in Set(snapshot.localFileURLs) {
            let info = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let bytes = Int64(info.fileSize ?? 0)
            let id: UUID
            if reuseResources, let old = imported[url], old.0 == info.contentModificationDate, old.1 == bytes {
                id = old.2
            } else {
                let resource = try await media.importFile(url, filename: url.lastPathComponent, mime: "application/octet-stream")
                id = resource.id
                if reuseResources { imported[url] = (info.contentModificationDate, bytes, id) }
            }
            replacements[url] = URL(string: "azurefish-media://" + id.uuidString.lowercased())!
        }
        return try snapshot.mappingFiles { url in
            guard let result = replacements[url] else { throw ChatMediaStoreError.invalidResource }; return result
        }
    }
    func materialize(_ snapshot: ChatDraftSnapshot, into directory: URL) async throws -> ChatDraftLoadResult {
        var replacements: [URL: URL] = [:]
        var missing = false
        for reference in Set(snapshot.localFileURLs) {
            guard reference.scheme == "azurefish-media", let id = reference.host.flatMap(UUID.init(uuidString:)) else {
                throw ChatMediaStoreError.invalidResource
            }
            do {
                let lease = try await media.lease(id)
                do {
                    let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(lease.pathExtension)
                    try FileManager.default.copyItem(at: lease, to: target)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
                    replacements[reference] = target
                    try await media.release(lease)
                } catch { try? await media.release(lease); throw error }
            } catch { missing = true }
        }
        func mapped(_ url: URL) throws -> URL {
            guard let result = replacements[url] else { throw ChatMediaStoreError.unavailable }; return result
        }
        var value = snapshot
        value.documents = snapshot.documents.compactMap { try? $0.mappingDraftFiles(mapped) }
        let ids = Set(value.documents.map(\.id))
        value.segments = snapshot.segments.filter { if case .attachment(let id) = $0 { return ids.contains(id) }; return true }
        value.media = snapshot.media.flatMap { group in
            let items = group.items.compactMap { try? $0.mappingDraftFiles(mapped) }
            return items.isEmpty ? nil : .init(id: group.id, items: items)
        }
        value.audio = snapshot.audio.flatMap { try? $0.mappingDraftFiles(mapped) }
        return .init(snapshot: value, hasMissingAttachments: missing)
    }
}
