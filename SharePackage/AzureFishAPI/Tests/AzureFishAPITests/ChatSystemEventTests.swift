import AzureFishProtocol
import Foundation
import Testing
@testable import AzureFishAPI

@Suite("系统消息客户端契约")
struct ChatSystemEventTests {
    @Test func structuredEventAndLatestMessageRoundTrip() throws {
        var wire = IMMessage()
        wire.messageUuid = UUID().uuidString.lowercased()
        wire.conversationID = UUID().uuidString.lowercased()
        wire.serverSeq = 1; wire.contentType = "system"; wire.contentSchemaVersion = 1
        wire.systemEvent.kind = "friendship_accepted"
        wire.systemEvent.relationshipID = UUID().uuidString.lowercased()
        wire.systemEvent.relationshipRevision = 2
        wire.systemEvent.requesterUserID = "requester"
        wire.systemEvent.accepterUserID = "accepter"
        var conversation = IMConversation()
        conversation.conversationID = wire.conversationID; conversation.latestMessage = wire
        let restored = try IMConversation(serializedBytes: conversation.serializedData())
        let model = ChatConversation(restored)
        #expect(model.latestMessage?.systemEvent?.relationshipRevision == 2)
        #expect(model.latestMessage?.systemEvent?.requesterID == "requester")
        #expect(model.latestMessage?.senderID == "")
        let encoded = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(ChatConversation.self, from: encoded) == model)
        wire.systemEvent.kind = "future_event"
        #expect(ChatMessage(wire).systemEvent?.kind == "future_event")
        #expect(ChatConversation(IMConversation()).latestMessage == nil)
        #expect(ChatMessage(IMMessage()).systemEvent == nil)
    }
}
