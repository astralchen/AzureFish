import AzureFishAPI
import Foundation
import Testing
@testable import AzureFishChat

@Suite("通讯录快照与离线恢复")
struct ChatDirectoryStoreTests {
    private func snapshot(_ contacts: [ChatContact], complete: Bool, baseline: String) throws -> ChatSnapshot {
        let object: [String: Any] = ["contacts": try JSONSerialization.jsonObject(with: JSONEncoder().encode(contacts)),
            "conversations": [], "token": "fixed", "nextCursor": complete ? "" : "next", "complete": complete,
            "baseline": baseline, "epoch": "fixture"]
        return try JSONDecoder().decode(ChatSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
    @Test func emptySnapshotAndInterruptedRecoveryPreserveCheckpointAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("db"), owner = UUID(), key = Data(repeating: 23, count: 32)
        let store = try ChatStore(url: url, key: key, environment: "test", userID: owner)
        #expect(try await !store.contactDirectorySnapshot().hasSnapshot)
        try await store.apply(snapshot: snapshot([], complete: false, baseline: "first"))
        #expect(try await !store.contactDirectorySnapshot().hasSnapshot)
        try await store.apply(snapshot: snapshot([], complete: true, baseline: "first"))
        let empty = try await store.contactDirectorySnapshot()
        #expect(empty.hasSnapshot && empty.contacts.isEmpty)
        // 游标过期后的分页快照尚未完成就退出，原检查点仍可恢复。
        try await store.apply(snapshot: snapshot([], complete: false, baseline: "replacement"))
        try await store.close()
        let reopened = try ChatStore(url: url, key: key, environment: "test", userID: owner)
        #expect(try await reopened.checkpoint()?.cursor == "first")
        #expect(try await reopened.contactDirectorySnapshot().hasSnapshot)
        try await reopened.apply(snapshot: snapshot([], complete: true, baseline: "replacement"))
        #expect(try await reopened.checkpoint()?.cursor == "replacement")
        try await reopened.close()
    }
    @Test func olderSnapshotCannotRestoreRelationshipAvatarOrDeletedProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 21, count: 32), environment: "test", userID: UUID())
        let old = try JSONDecoder().decode(ChatContact.self, from: Data(#"{"id":"relationship","peer":{"id":"peer","nickname":"Before","version":1,"avatarID":"old"},"state":"friend","requesterID":"","revision":1,"updatedAt":100,"semanticsVersion":2,"isContact":true}"#.utf8))
        var current = old
        current.revision = 4; current.isContact = false; current.remark = "Private"
        current.peer.version = 6; current.peer.nickname = "After"; current.peer.avatarID = nil
        try await store.save(current)
        try await store.apply(snapshot: snapshot([old], complete: false, baseline: "new"))
        #expect(try await store.contactDirectorySnapshot().contacts == [current])
        var relationUpdate = old
        relationUpdate.revision = 5; relationUpdate.remark = "New note"; relationUpdate.isContact = false
        try await store.save(relationUpdate)
        current.revision = 5; current.remark = "New note"
        #expect(try await store.contacts() == [current])
        current.peer.version = 7; current.peer.deleted = true
        try await store.save(current)
        try await store.apply(snapshot: snapshot([old], complete: true, baseline: "new"))
        let restored = try await store.contactDirectorySnapshot()
        #expect(restored.hasSnapshot && restored.contacts == [current])
        try await store.close()
    }
}
