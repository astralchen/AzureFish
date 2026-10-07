import AzureFishAPI
import AzureFishStorage
import Foundation
import Testing
@testable import AzureFishChat

@Suite("时间线窗口与导入恢复")
struct ChatTimelineAndImportsTests {
    private func message(_ sequence: Int64) -> ChatMessage {
        .init(id: "m\(sequence)", conversationID: "conversation", clientID: "c\(sequence)", serverID: "s\(sequence)",
              senderID: "sender", deviceID: "device", sequence: sequence, createdAt: sequence, revision: 1,
              kind: "text", schemaVersion: 1, text: "fixture \(sequence)", textRuns: nil, linkURL: nil, revoked: false,
              receipt: .init(expected: 1, delivered: 0, read: 0, revision: 1), assets: [], systemEvent: nil)
    }
    @Test func windowPreserves350MessagesAndRefreshesRevisions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 71, count: 32), environment: "fixture", userID: UUID())
        let user = store.userID.uuidString.lowercased()
        let directory: [String: Any] = ["id": "conversation", "kind": "group", "title": "测试", "ownerID": user,
            "members": [["id": user, "active": true, "intervals": [["joined": 1, "left": 0]],
                         "profile": ["id": user, "nickname": "自己", "version": 1]]],
            "revision": 1, "boundaryRevision": 1, "latest": 1000, "closed": false,
            "readState": ["read": 0, "delivered": 0, "unread": 0, "through": 0, "revision": 1]]
        try await store.save(JSONDecoder().decode(ChatConversation.self, from: JSONSerialization.data(withJSONObject: directory)))
        for value in (1...350).map({ message(Int64($0)) }) { try await store.save(value) }
        var window = ChatTimelineWindow()
        let initial = try await window.messages(in: store, conversation: "conversation")
        #expect(initial.count == 200 && initial.first?.sequence == 151)
        window.include(initial)
        #expect(window.historyBefore(pageCursor: nil) == 151)
        #expect(window.historyBefore(pageCursor: 201) == 151)
        #expect(window.historyBefore(pageCursor: 100) == 100)
        let older = try await store.messages("conversation", before: 151, limit: 200)
        window.include(older)
        let all = try await window.messages(in: store, conversation: "conversation")
        #expect(all.map(\.sequence) == Array(1...350).map(Int64.init))
        #expect(Set(all.map(\.id)).count == 350)
        try await store.save(message(351))
        var revoked = message(20); revoked.revoked = true; revoked.revision = 2
        try await store.save(revoked)
        try await store.hide(message: "m30")
        let refreshed = try await window.messages(in: store, conversation: "conversation")
        #expect(refreshed.count == 350 && refreshed.last?.sequence == 351)
        #expect(refreshed.first?.sequence == 1 && refreshed.first(where: { $0.id == "m20" })?.revoked == true)
        #expect(!refreshed.contains(where: { $0.id == "m30" }))
        let context = try await store.messageContext("m21", conversation: "conversation")
        #expect(context.contains(where: { $0.id == "m21" }))
        #expect(try await window.messages(in: store, conversation: "conversation").first?.sequence == 1)
        try await store.close()
    }
    @Test func legacyDatabaseMigratesAndImportRecoveryProtectsReferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 72, count: 32), user = UUID(), url = root.appendingPathComponent("db")
        let legacy = try AccountDatabase(url: url, key: key, environment: "fixture", userID: user, baseline: ChatSchema.create)
        try legacy.close()
        let store = try ChatStore(url: url, key: key, environment: "fixture", userID: user)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: key, environment: "fixture", userID: user)
        let source = root.appendingPathComponent("source"); try Data("fictional bytes".utf8).write(to: source)
        let batch = try await store.beginMediaImport()
        let kept = try await store.importMedia(source, filename: "source", mime: "application/octet-stream", using: media, batch: batch)
        let discarded = try await store.importMedia(source, filename: "source", mime: "application/octet-stream", using: media, batch: batch)
        try await store.requestMediaCleanup([kept.id, discarded.id])
        try await store.cleanupMedia(using: media)
        #expect(try await media.read(discarded.id, index: 0) == Data("fictional bytes".utf8))
        let attachment = StoredDraftAttachment.file(.init(id: UUID(), resourceID: kept.id, displayName: "source", typeIdentifier: "public.data", byteCount: 15))
        try await store.saveEditorDraft(.init(conversationID: "draft", documents: [attachment]), text: "", conversation: "draft", completingImport: batch)
        try await store.cleanupMedia(using: media)
        #expect(try await media.read(kept.id, index: 0) == Data("fictional bytes".utf8))
        await #expect(throws: (any Error).self) { _ = try await media.read(discarded.id, index: 0) }
        let abandoned = try await store.beginMediaImport()
        let orphan = try await store.importMedia(source, filename: "source", mime: "application/octet-stream", using: media, batch: abandoned)
        try await store.close()
        let reopened = try ChatStore(url: url, key: key, environment: "fixture", userID: user)
        try await reopened.recoverMediaImports(using: media)
        await #expect(throws: (any Error).self) { _ = try await media.read(orphan.id, index: 0) }
        #expect(try await media.read(kept.id, index: 0) == Data("fictional bytes".utf8))
        let failing = try await reopened.beginMediaImport()
        await #expect(throws: (any Error).self) {
            _ = try await reopened.importMedia(root.appendingPathComponent("missing"), filename: "missing", mime: "application/octet-stream", using: media, batch: failing)
        }
        try await reopened.cancelMediaImport(failing)
        try await reopened.cleanupMedia(using: media)
        try await reopened.close()
    }
    @Test func failedBusinessCommitKeepsImportPinnedAndOtherWindowReferenceSafe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = UUID(), key = Data(repeating: 73, count: 32)
        let database = try ChatStore.openDatabase(url: root.appendingPathComponent("db"), key: key, environment: "fixture", userID: user)
        let first = try ChatStore(database: database), second = try ChatStore(database: database)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: key, environment: "fixture", userID: user)
        let source = root.appendingPathComponent("source"); try Data("shared fictional media".utf8).write(to: source)
        let batch = try await first.beginMediaImport()
        let local = try await first.importMedia(source, filename: "source", mime: "application/octet-stream", using: media, batch: batch)
        let outgoing = ChatOutgoing(conversationID: "one", deviceID: UUID(), text: "A")
        let wrong = ChatOutgoing(conversationID: "two", deviceID: UUID(), text: "B")
        await #expect(throws: ChatStoreError.scopeMismatch) {
            try await first.enqueueComposition([.message(outgoing), .message(wrong)], conversation: "one", completingImport: batch)
        }
        try await second.requestMediaCleanup([local.id]); try await second.cleanupMedia(using: media)
        #expect(try await media.read(local.id, index: 0).count == 22)
        let attachment = StoredDraftAttachment.file(.init(id: UUID(), resourceID: local.id, displayName: "source", typeIdentifier: "public.data", byteCount: 22))
        try await second.saveEditorDraft(.init(conversationID: "other", documents: [attachment]), text: "", conversation: "other")
        try await first.cancelMediaImport(batch); try await first.cleanupMedia(using: media)
        #expect(try await media.read(local.id, index: 0).count == 22)
        try await first.close(); try await second.close(); try database.close()
    }

}
