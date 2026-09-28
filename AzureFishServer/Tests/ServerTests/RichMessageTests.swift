@testable import Server
import Foundation
import Testing
import VaporTesting

@Suite("真实聊天富文本与链接")
struct RichMessageTests {
    @Test func roundTripValidationAndRevocation() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "rich_a"), b = try await auth(app, name: "rich_b")
            let chat = try await direct(app, a, b)
            var request = outgoing(chat, a, text: "粗体 العربية 👩🏽‍💻")
            var run = IMTextRun(); run.text = request.text; run.style = 15
            request.textRuns = [run]
            let message = try await imCall(app, "messages/send", request, IMMessage.self, a)
            #expect(message.textRuns == [run])
            #expect(try await imCall(app, "messages/send", request, IMMessage.self, a).messageUuid == message.messageUuid)
            var invalid = outgoing(chat, a, text: "mismatch"); invalid.textRuns = [run]
            #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", invalid, token: a.accessToken)) == "VALIDATION_FAILED")
            invalid = outgoing(chat, a, text: run.text); run.style = 16; invalid.textRuns = [run]
            #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", invalid, token: a.accessToken)) == "VALIDATION_FAILED")
            var link = outgoing(chat, a, text: "https://example.com/path?q=1")
            link.contentType = "link"; link.linkURL = link.text
            let sentLink = try await imCall(app, "messages/send", link, IMMessage.self, a)
            #expect(sentLink.linkURL == link.text && sentLink.text == link.text)
            let history = try await imCall(app, "history", historyInput(chat), IMHistoryResponse.self, b)
            #expect(history.messages.contains(where: { $0.messageUuid == sentLink.messageUuid && $0.linkURL == link.linkURL }))
            for source in [message, sentLink] {
                var revoke = IMRevokeRequest(); revoke.operationID = UUID().uuidString
                revoke.conversationID = chat.conversationID; revoke.messageUuid = source.messageUuid
                let result = try await imCall(app, "messages/revoke", revoke, IMMessage.self, a)
                #expect(result.revoked && result.text.isEmpty && result.textRuns.isEmpty && result.linkURL.isEmpty)
            }
            for url in ["file:///tmp/secret", "javascript:alert(1)", "https://"] {
                var invalidLink = outgoing(chat, a, text: url); invalidLink.contentType = "link"; invalidLink.linkURL = url
                #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", invalidLink, token: a.accessToken)) == "VALIDATION_FAILED")
            }
        }
    }
}
