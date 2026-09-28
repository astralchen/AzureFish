import AzureFishAPI
import Foundation
import Testing
@testable import AzureFishChat

@Suite("有序混合草稿")
struct ChatCompositionTests {
    @Test func removingMessagePurgesEveryPresentationRevisionAndRejectsLateResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatStore(url: root.appendingPathComponent("cache.sqlite"), key: Data(repeating: 8, count: 32), environment: "fixture", userID: UUID())
        let message = UUID().uuidString, first = UUID(), second = UUID()
        try await store.savePresentation(["file": "azurefish-media://" + first.uuidString], message: message)
        try await store.savePresentation(["file": "azurefish-media://" + second.uuidString], message: message)
        try await store.savePresentation("识别结果", message: message, transcript: true)
        try await store.hide(message: message)
        #expect(try await Set(store.mediaInvalidations()) == Set([first, second]))
        let transcript: String? = try await store.meta("transcript:" + message)
        #expect(transcript == nil)
        do {
            try await store.savePresentation("迟到结果", message: message, transcript: true)
            Issue.record("本机删除后不能恢复展示缓存")
        } catch ChatStoreError.unavailable {}
        try await store.close()
    }
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
        try await reopened.saveTransfer(other, id: other.id)
        try await reopened.removeTransfer(other.id)
        #expect(try await reopened.orderedMessageIDs(conversation: "other").isEmpty)
        try await reopened.close()
    }
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
    @Test func olderOutboxDecodesWithoutRichFields() throws {
        let value = ChatOutgoing(conversationID: "test", deviceID: UUID(), text: "old")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        json.removeValue(forKey: "textRuns"); json.removeValue(forKey: "linkURL")
        let decoded = try JSONDecoder().decode(ChatOutgoing.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.text == "old" && decoded.textRuns == nil && decoded.linkURL == nil)
    }
}
