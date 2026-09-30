import AzureFishAPI
import Foundation
import Testing
@testable import AzureFishChat

@Suite("有序混合草稿")
struct ChatCompositionTests {
    /// 验证移除消息清理各版本展示资源并拒绝迟到结果。
    @Test func removingMessagePurgesEveryPresentationRevisionAndRejectsLateResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatStore(url: root.appendingPathComponent("cache.sqlite"), key: Data(repeating: 8, count: 32), environment: "fixture", userID: UUID())
        let message = UUID().uuidString, first = UUID(), second = UUID()
        try await store.savePresentation(.init(conversationID: "chat", documents: [.file(.init(id: UUID(), resourceID: first, displayName: "first", typeIdentifier: "public.data", byteCount: 1))]), message: message)
        try await store.savePresentation(.init(conversationID: "chat", documents: [.file(.init(id: UUID(), resourceID: second, displayName: "second", typeIdentifier: "public.data", byteCount: 1))]), message: message)
        try await store.saveTranscript("识别结果", message: message)
        try await store.hide(message: message)
        #expect(try await Set(store.mediaInvalidations()) == Set([first, second]))
        let transcript: String? = try await store.transcript(message: message)
        #expect(transcript == nil)
        do {
            try await store.saveTranscript("迟到结果", message: message)
            Issue.record("本机删除后不能恢复展示缓存")
        } catch ChatStoreError.unavailable {}
        try await store.close()
    }
    /// 验证媒体上传占位在重开及取消后仍维护消息发送顺序。
    @Test func mediaBlocksFollowingTextAcrossReopenAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 7, count: 32), user = UUID(), conversation = UUID().uuidString, device = UUID()
        let url = root.appendingPathComponent("test.sqlite")
        let first = try ChatStore(url: url, key: key, environment: "fixture", userID: user)
        let media = ChatUploadBatch(conversation: conversation, kind: "file", items: [], deviceID: device)
        let text = ChatOutgoing(conversationID: conversation, deviceID: device, text: "富文本", textRuns: [.init(text: "富文本", style: 3)])
        try await first.saveDraft(.init(text: "草稿"), conversation: conversation)
        try await first.enqueueComposition([.upload(media), .message(text)], conversation: conversation)
        #expect(try await first.draft(conversation).text.isEmpty)
        #expect(try await first.canTransmit(text) == false)
        try await first.close()
        let reopened = try ChatStore(url: url, key: key, environment: "fixture", userID: user)
        #expect(try await reopened.canTransmit(text) == false)
        #expect(try await reopened.pending().first?.outgoing.textRuns == text.textRuns)
        let outgoingMedia = ChatOutgoing(conversationID: conversation, deviceID: device, kind: "file", id: media.messageID,
            clientID: media.clientID, operationID: media.operationID)
        try await reopened.submitTransfer(outgoingMedia, transfer: media.id)
        #expect(try await reopened.pending().map(\.outgoing.id) == [media.messageID, text.id])
        #expect(try await reopened.canTransmit(outgoingMedia))
        #expect(try await reopened.canTransmit(text) == false)
        try await reopened.removePending(message: media.messageID.uuidString.lowercased())
        #expect(try await reopened.canTransmit(text))
        let other = ChatUploadBatch(conversation: "other", kind: "file", items: [], deviceID: device)
        try await reopened.saveTransfer(other)
        try await reopened.removeTransfer(other.id)
        #expect(try await reopened.orderedMessageIDs(conversation: "other").isEmpty)
        try await reopened.close()
    }
    /// 验证组合发送事务失败时保留草稿且不留下部分任务。
    @Test func failedCompositionPreservesDraftAndWritesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatStore(url: root.appendingPathComponent("test.sqlite"), key: Data(repeating: 8, count: 32), environment: "fixture", userID: UUID())
        let first = ChatOutgoing(conversationID: "one", deviceID: UUID(), text: "A")
        let wrong = ChatOutgoing(conversationID: "two", deviceID: UUID(), text: "B")
        try await store.saveDraft(.init(text: "keep"), conversation: "one")
        await #expect(throws: ChatStoreError.scopeMismatch) {
            try await store.enqueueComposition([.message(first), .message(wrong)], conversation: "one")
        }
        #expect(try await store.pending().isEmpty)
        #expect(try await store.orderedMessageIDs(conversation: "one").isEmpty)
        #expect(try await store.draft("one").text == "keep")
        try await store.close()
    }
    /// 验证缺少富文本字段的旧版 outbox 仍可解码。
    @Test func olderOutboxDecodesWithoutRichFields() throws {
        let value = ChatOutgoing(conversationID: "test", deviceID: UUID(), text: "old")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        json.removeValue(forKey: "textRuns"); json.removeValue(forKey: "linkURL")
        let decoded = try JSONDecoder().decode(ChatOutgoing.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.text == "old" && decoded.textRuns == nil && decoded.linkURL == nil)
    }
}
