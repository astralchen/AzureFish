import AzureFishAPI
import CryptoKit
import Foundation
import Testing

@testable import AzureFishChat

@Suite("聊天加密存储")
struct ChatStoreTests {
    /// 验证已取消上传不能被迟到回调转为发送消息。
    @Test func cancelledTransferCannotBecomeMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let store = try ChatStore(
            url: root.appendingPathComponent("main.sqlite"), key: key, environment: "test", userID: UUID())
        var batch = ChatUploadBatch(conversation: UUID().uuidString, kind: "file", items: [], deviceID: UUID())
        let stale = batch
        batch.cancelRequested = true
        try await store.saveTransfer(batch)
        try await store.saveTransfer(stale)
        #expect(try await store.transfers().first?.cancelRequested == true)
        let outgoing = ChatOutgoing(
            conversationID: batch.conversation, deviceID: batch.deviceID, kind: "file", id: batch.messageID,
            clientID: batch.clientID, operationID: batch.operationID)
        await #expect(throws: ChatStoreError.transferCancelled) {
            try await store.submitTransfer(outgoing, transfer: batch.id)
        }
        #expect(try await store.pending().isEmpty)
        try await store.removeTransfer(batch.id)
        try await store.saveTransfer(stale)
        #expect(try await store.transfers().isEmpty)
        try await store.close()
    }
    /// 验证聊天数据库账号隔离及关闭重开。
    @Test func accountIsolationAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let user = UUID()
        let url = root.appendingPathComponent("main.sqlite")
        let store = try ChatStore(url: url, key: key, environment: "test", userID: user)
        let outgoing = ChatOutgoing(
            conversationID: UUID().uuidString, deviceID: UUID(), text: "fictional secret العربية")
        try await store.enqueue(outgoing)
        try await store.saveDraft(.init(text: "draft secret"), conversation: outgoing.conversationID)
        try await store.close()
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("fictional secret"))
        #expect(throws: (any Error).self) {
            _ = try ChatStore(url: url, key: Data(repeating: 0, count: 32), environment: "test", userID: user)
        }
        #expect(throws: (any Error).self) { _ = try ChatStore(url: url, key: key, environment: "other", userID: user) }
        let reopened = try ChatStore(url: url, key: key, environment: "test", userID: user)
        #expect(try await reopened.pending().first?.outgoing == outgoing)
        #expect(try await reopened.draft(outgoing.conversationID).text == "draft secret")
        try await reopened.close()
    }
    /// 验证加密分块恢复及跨资源替换检测。
    @Test func encryptedChunksResumeAndSubstitution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let user = UUID()
        let source = root.appendingPathComponent("fixture.bin")
        let bytes = Data(repeating: 0x67, count: 4 * 1024 * 1024 + 73)
        try bytes.write(to: source)
        let mediaRoot = root.appendingPathComponent("media")
        let store = try ChatMediaStore(root: mediaRoot, key: key, environment: "test", userID: user)
        let imported = try await store.importFile(source, filename: "fixture.bin", mime: "application/octet-stream")
        #expect(try await store.completed(imported.id) == Set([0, 1]))
        let lease = try await store.lease(imported.id)
        #expect(try Data(contentsOf: lease) == bytes)
        try await store.release(lease)
        let reopened = try ChatMediaStore(root: mediaRoot, key: key, environment: "test", userID: user)
        #expect(try await reopened.read(imported.id, index: 1).count == 73)
        let part = mediaRoot.appendingPathComponent(imported.id.uuidString.lowercased() + "/0.blob")
        var corrupted = try Data(contentsOf: part)
        corrupted[40] ^= 1
        try corrupted.write(to: part)
        await #expect(throws: (any Error).self) { _ = try await reopened.read(imported.id, index: 0) }
        #expect(throws: (any Error).self) { _ = try ChatMediaStore(root: mediaRoot, key: key, environment: "test", userID: UUID()) }
    }
}
