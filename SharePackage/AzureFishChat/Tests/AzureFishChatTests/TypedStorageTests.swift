import AzureFishAPI
import AzureFishStorage
import Foundation
import GRDB
import Testing
@testable import AzureFishChat

@Suite("类型化关系存储")
struct TypedStorageTests {
    /// 创建唯一临时测试目录；调用方负责在测试结束时清理。
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    /// 构造指定内容或序列的虚构消息，供本地存储断言使用。
    private func message(_ index: Int, kind: String = "text", version: Int32 = 1) -> ChatMessage {
        .init(id: "m\(index)", conversationID: "conversation", clientID: "c\(index)", serverID: "s\(index)",
            senderID: "sender", deviceID: "device", sequence: Int64(index), createdAt: Int64(index), revision: 1,
            kind: kind, schemaVersion: version, text: "文字 العربية \(index)", textRuns: nil, linkURL: nil, revoked: false,
            receipt: .init(expected: 3, delivered: 2, read: 1, revision: 4), assets: [], systemEvent: nil)
    }
    /// 验证内容类型、未知版本及共享资产在类型化存储中往返恢复。
    @Test func contentsUnknownVersionsAndSharedAssetsRoundTrip() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let user = UUID(), key = Data(repeating: 44, count: 32), url = root.appendingPathComponent("db")
        let store = try ChatStore(url: url, key: key, environment: "fixture", userID: user)
        let resources: [ChatResource] = ["original", "thumbnail", "paired_video"].map {
            .init(id: UUID().uuidString.lowercased(), role: $0, filename: "fixture", mime: "image/jpeg", bytes: 3, sha256: "abc")
        }
        let asset = ChatAsset(id: "live-photo", kind: "image", resources: resources, width: 640, height: 480,
            duration: 1250, animated: false, waveform: [0.25, 0, 0.25], version: 2)
        var values = [message(1), message(2, kind: "link"), message(3, kind: "system"), message(4, kind: "media"),
                      message(5, kind: "future.payment", version: 7), message(6, version: 99)]
        values[0].textRuns = [.init(text: "", style: 0), .init(text: "重复", style: 3), .init(text: "重复", style: 3)]
        values[1].textRuns = []; values[1].linkURL = ""
        values[2].systemEvent = .init(kind: "contact_added", relationshipID: "r", relationshipRevision: 8, requesterID: "a", accepterID: "b")
        values[3].assets = [asset, asset]
        values[4].assets = [asset]; values[4].linkURL = "https://example.invalid/future"
        #expect(!values[4].isKnownContent && !values[5].isKnownContent)
        for value in values { try await store.save(value) }
        try await store.close()
        let reopened = try ChatStore(url: url, key: key, environment: "fixture", userID: user)
        #expect(try await reopened.messages("conversation") == values)
        let database = await reopened.db
        #expect(try database.read { try ResourceRecord.fetchCount($0) } == 3)
        #expect(try database.read { try MessageTextRecord.fetchOne($0, key: "m1")?.text } == values[0].text)
        #expect(throws: (any Error).self) {
            try database.write { try MessageTextRecord(messageID: "missing-parent", text: "orphan").insert($0) }
        }
        try await reopened.close()
    }
    /// 验证草稿结构保留顺序、空值及 Live Photo 配对资源。
    @Test func draftGraphPreservesOrderEmptyValuesAndLivePhoto() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try ChatStore.openDatabase(url: root.appendingPathComponent("db"), key: Data(repeating: 45, count: 32), environment: "fixture", userID: UUID())
        defer { try? database.close() }
        let store = try ChatStore(database: database), other = try ChatStore(database: database)
        let file = StoredDraftFile(id: UUID(), resourceID: UUID(), displayName: "", typeIdentifier: "public.data", byteCount: 0)
        let item = StoredDraftMediaItem(id: UUID(), assetIdentifier: "", originalID: UUID(), thumbnailID: UUID(),
            pairedVideoID: UUID(), width: 10.5, height: 20.5, duration: nil, animated: false)
        let value = StoredChatDraft(revision: UInt64.max, conversationID: "local-direct:peer",
            segments: [.text("  \n"), .richText([]), .attachment(file.id), .attachment(file.id)],
            documents: [.file(file), .link(.init(id: UUID(), url: "https://example.invalid", title: "")), .file(file)],
            media: .init(id: UUID(), items: [item, item]), audio: .init(id: UUID(), resourceID: UUID(), duration: 1.5, waveform: [0, 0.5, 0.5], transcript: ""))
        try await store.saveEditorDraft(value, text: "  \n", conversation: value.conversationID)
        #expect(try await other.editorDraftState(value.conversationID).editor == value)
        try await store.close()
        #expect(try await other.editorDraftState(value.conversationID).editor == value)
        try await other.close()
    }
    /// 验证共享资源释放全部引用后才清理且失败可重试。
    @Test func sharedResourceCleanupWaitsForEveryReferenceAndRetries() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let user = UUID(), key = Data(repeating: 46, count: 32)
        let store = try ChatStore(url: root.appendingPathComponent("db"), key: key, environment: "fixture", userID: user)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: key, environment: "fixture", userID: user)
        let source = root.appendingPathComponent("source"); try Data("private bytes".utf8).write(to: source)
        let resource = try await media.importFile(source, filename: "fixture.txt", mime: "text/plain")
        let file = StoredDraftAttachment.file(.init(id: UUID(), resourceID: resource.id, displayName: "fixture", typeIdentifier: "public.text", byteCount: 13))
        let physical = ChatResource(id: resource.id.uuidString.lowercased(), role: resource.input.role,
            filename: resource.input.filename, mime: resource.input.mime, bytes: resource.input.bytes, sha256: resource.input.sha256)
        let asset = ChatAsset(id: "shared", kind: "file", resources: [physical], width: 0, height: 0,
            duration: 0, animated: false, waveform: [], version: 1)
        var first = message(1, kind: "file"), second = message(2, kind: "file")
        first.assets = [asset]; second.assets = [asset]
        try await store.save(first); try await store.save(second)
        try await store.hide(message: first.id)
        try await store.cleanupMedia(using: media)
        #expect(try await media.read(resource.id, index: 0) == Data("private bytes".utf8))
        try await store.savePresentation(.init(conversationID: "conversation", documents: [file]), message: "a")
        try await store.savePresentation(.init(conversationID: "conversation", documents: [file]), message: "b")
        try await store.saveEditorDraft(.init(conversationID: "draft", documents: [file]), text: "", conversation: "draft")
        try await store.hide(message: "a"); try await store.cleanupMedia(using: media)
        #expect(try await media.read(resource.id, index: 0) == Data("private bytes".utf8))
        try await store.hide(message: "b"); try await store.hide(message: second.id)
        try await store.cleanupMedia(using: media)
        #expect(try await store.mediaInvalidations().isEmpty)
        try await store.saveEditorDraft(.init(conversationID: "draft"), text: "", conversation: "draft")
        #expect(try await store.mediaInvalidations() == [resource.id])
        let database = await store.db
        try database.registerResourceReferences(domain: "failure-fixture") { _, _ in throw ChatStoreError.unavailable }
        await #expect(throws: ChatStoreError.unavailable) { try await store.cleanupMedia(using: media) }
        #expect(try await store.mediaInvalidations() == [resource.id])
        try database.registerResourceReferences(domain: "failure-fixture") { _, _ in false }
        try await store.cleanupMedia(using: media)
        #expect(try await store.mediaInvalidations().isEmpty)
        await #expect(throws: (any Error).self) { try await media.read(resource.id, index: 0) }
        try await store.close()
    }
    /// 验证消息身份冲突回滚整批实体和检查点。
    @Test func identityConflictRollsBackBatchAndCheckpoint() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 47, count: 32), environment: "fixture", userID: UUID())
        let original = message(1); try await store.save(original)
        var conflict = original; conflict.conversationID = "other"
        await #expect(throws: ChatStoreError.scopeMismatch) { try await store.save(conflict) }
        try await store.saveCheckpoint(.init(cursor: "0", epoch: "fixture"))
        let records = try [message(2), conflict].map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        let events = try JSONDecoder().decode(ChatEvents.self, from: JSONSerialization.data(withJSONObject: [
            "base": "0", "next": "2", "epoch": "fixture", "hasMore": false,
            "events": [["position": 1, "kind": "message", "message": records[0]], ["position": 2, "kind": "message", "message": records[1]]]
        ]))
        await #expect(throws: ChatStoreError.scopeMismatch) { try await store.apply(events: events, expected: .init(cursor: "0", epoch: "fixture")) }
        #expect(try await store.checkpoint()?.cursor == "0")
        #expect(try await store.messages("conversation") == [original])
        let outgoing = ChatOutgoing(conversationID: "conversation", deviceID: UUID(), text: "immutable")
        try await store.enqueue(outgoing)
        var pending = try #require(try await store.pending().first)
        pending.state = "failed"; pending.failure = "fixture"
        try await store.update(pending)
        #expect(try await store.pending().first?.outgoing == outgoing)
        try await store.close()
    }
    /// 验证分页批量装配查询数量受控且时间线查询使用索引。
    @Test func pageQueriesRemainBoundedAndUseTimelineIndex() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try ChatStore.openDatabase(url: root.appendingPathComponent("db"), key: Data(repeating: 48, count: 32), environment: "fixture", userID: UUID())
        defer { try? database.close() }
        let store = try ChatStore(database: database)
        for index in 1...30 { try await store.save(message(index)) }
        let counts: [Int] = try database.read { db in
            // 先建立 GRDB 的主键／表结构缓存，计数只比较关联装配查询。
            _ = try MessageRepository.fetch(MessageRecord.limit(1), in: db)
            var counts: [Int] = []
            for size in [1, 30] {
                var count = 0
                db.trace { _ in count += 1 }
                _ = try MessageRepository.fetch(MessageRecord.order(MessageRecord.Columns.sequence).limit(size), in: db)
                db.trace(nil); counts.append(count)
            }
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT * FROM message WHERE conversation_id = ? ORDER BY sequence DESC LIMIT 30", arguments: ["conversation"])
            #expect(plan.contains { ($0["detail"] as String).contains("idx_message_0") })
            return counts
        }
        #expect(counts[0] == counts[1])
        #expect(counts[1] <= 15)
        try await store.close()
    }
}
