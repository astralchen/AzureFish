@testable import Server
import Fluent
import FluentSQLiteDriver
import Foundation
import SwiftProtobuf
import Testing
import VaporTesting

func imCall<I: Message, O: Message>(_ app: Application, _ path: String, _ input: I, _ output: O.Type, _ user: AuthResponse) async throws -> O {
    let response = try await send(app, .POST, "/v1/im/" + path, input, token: user.accessToken)
    guard response.status == .ok else {
        Issue.record("IM request \(path) failed: \(try errorCode(response))")
        throw APIError(response.status, try errorCode(response))
    }
    return try decode(output, response)
}
func direct(_ app: Application, _ a: AuthResponse, _ b: AuthResponse) async throws -> IMConversation {
    var request = IMResolveRequest(); request.operationID = UUID().uuidString; request.peerUserID = b.userID
    return try await imCall(app, "conversations/resolve", request, IMConversation.self, a)
}
func group(_ app: Application, _ a: AuthResponse, _ members: [AuthResponse]) async throws -> IMConversation {
    var request = IMCreateGroupRequest(); request.operationID = UUID().uuidString; request.title = "虚构群聊"
    request.memberUserIds = members.map(\.userID)
    return try await imCall(app, "groups/create", request, IMConversation.self, a)
}
func outgoing(_ conversation: IMConversation, _ user: AuthResponse, text: String = "机密虚构消息 العربية 繁體") -> IMSendRequest {
    var input = IMSendRequest(); input.operationID = UUID().uuidString; input.messageUuid = UUID().uuidString
    input.clientMessageID = UUID().uuidString; input.conversationID = conversation.conversationID
    input.deviceID = user.deviceID; input.contentType = "text"; input.contentSchemaVersion = 1; input.text = text; return input
}
func historyInput(_ conversation: IMConversation, limit: Int32 = 0) -> IMHistoryRequest {
    var input = IMHistoryRequest(); input.conversationID = conversation.conversationID; input.limit = limit; return input
}
func groupChange(_ conversation: IMConversation, action: String, target: String = "") -> IMUpdateGroupRequest {
    var input = IMUpdateGroupRequest(); input.operationID = UUID().uuidString; input.conversationID = conversation.conversationID
    input.expectedRevision = conversation.serverRevision; input.action = action; input.memberUserID = target; return input
}
func watermark(_ conversation: IMConversation, through: Int64) -> IMWatermarkRequest {
    var input = IMWatermarkRequest(); input.operationID = UUID().uuidString; input.conversationID = conversation.conversationID; input.throughSeq = through; return input
}
func conversationInput(_ conversation: IMConversation) -> IMConversationRequest {
    var input = IMConversationRequest(); input.conversationID = conversation.conversationID; return input
}

@Suite("IM 接口", .serialized)
struct IMTests {
    @Test func uniqueDirectAndConcurrentSendDeduplication() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "im_a"), b = try await auth(app, name: "im_b")
            async let left = direct(app, a, b)
            async let right = direct(app, b, a)
            let (one, two) = try await (left, right)
            #expect(one.conversationID == two.conversationID)
            #expect(try await IMConversationRecord.query(on: app.db).count() == 1)
            let request = outgoing(one, a)
            async let first = imCall(app, "messages/send", request, IMMessage.self, a)
            async let second = imCall(app, "messages/send", request, IMMessage.self, a)
            let (message, duplicate) = try await (first, second)
            #expect(message == duplicate && message.serverSeq == 1)
            var retry = request; retry.operationID = UUID().uuidString
            #expect(try await imCall(app, "messages/send", retry, IMMessage.self, a).messageUuid == message.messageUuid)
            retry.operationID = UUID().uuidString; retry.text = "冲突正文"
            #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", retry, token: a.accessToken)) == "MESSAGE_ID_CONFLICT")
            retry = request; retry.text = "操作 ID 冲突"
            #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", retry, token: a.accessToken)) == "OPERATION_CONFLICT")
            #expect(try await IMMessageRecord.query(on: app.db).count() == 1)
            let state = try await imCall(app, "conversations/get", conversationInput(one), IMConversation.self, b)
            #expect(state.readState.unreadCount == 1 && state.latestSeq == 1)
            #expect(try await imCall(app, "conversations/get", conversationInput(one), IMConversation.self, a).readState.unreadCount == 0)
        }
    }
    @Test func authorizationValidationAndCrossAccountIsolation() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "im_a"), b = try await auth(app, name: "im_b"), outsider = try await auth(app, name: "im_c")
            let chat = try await direct(app, a, b)
            #expect(try await send(app, .POST, "/v1/im/history", historyInput(chat)).status == .unauthorized)
            #expect(try errorCode(await send(app, .POST, "/v1/im/history", historyInput(chat), token: outsider.accessToken)) == "CONVERSATION_NOT_FOUND")
            #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", outgoing(chat, outsider), token: outsider.accessToken)) == "CONVERSATION_NOT_FOUND")
            var message = outgoing(chat, a); message.deviceID = b.deviceID
            #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", message, token: a.accessToken)) == "DEVICE_MISMATCH")
            message = outgoing(chat, a); message.contentType = "image"
            #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", message, token: a.accessToken)) == "UNSUPPORTED_CONTENT")
            message = outgoing(chat, a, text: String(repeating: "x", count: 16384))
            #expect(try await imCall(app, "messages/send", message, IMMessage.self, a).text == message.text)
            message = outgoing(chat, a, text: String(repeating: "x", count: 16385))
            #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", message, token: a.accessToken)) == "VALIDATION_FAILED")
            var lookup = IMLookupUserRequest(); lookup.accountName = " IM_B "
            #expect(try await imCall(app, "users/lookup", lookup, IMPublicUser.self, a).userID == b.userID)
            let read = watermark(chat, through: 2)
            #expect(try errorCode(await send(app, .POST, "/v1/im/read", read, token: b.accessToken)) == "VALIDATION_FAILED")
        }
    }
    @Test func groupOwnershipVersionsAndMembershipHistory() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "im_a"), b = try await auth(app, name: "im_b"), c = try await auth(app, name: "im_c")
            var chat = try await group(app, a, [b])
            let first = try await imCall(app, "messages/send", outgoing(chat, a), IMMessage.self, a)
            let staleHistory = try await imCall(app, "history", historyInput(chat, limit: 1), IMHistoryResponse.self, b)
            let add = groupChange(chat, action: "add", target: c.userID)
            #expect(try errorCode(await send(app, .POST, "/v1/im/groups/update", add, token: b.accessToken)) == "OWNER_REQUIRED")
            chat = try await imCall(app, "groups/update", add, IMConversation.self, a)
            #expect(chat.members.count == 3)
            var stale = add; stale.operationID = UUID().uuidString
            #expect(try errorCode(await send(app, .POST, "/v1/im/groups/update", stale, token: a.accessToken)) == "CONVERSATION_VERSION_CONFLICT")
            #expect(try await imCall(app, "history", historyInput(chat), IMHistoryResponse.self, c).messages.isEmpty)
            chat = try await imCall(app, "groups/update", groupChange(chat, action: "remove", target: b.userID), IMConversation.self, a)
            let second = try await imCall(app, "messages/send", outgoing(chat, a), IMMessage.self, a)
            #expect(second.serverSeq == 2)
            #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", outgoing(chat, b), token: b.accessToken)) == "CONVERSATION_CLOSED")
            let left = try await imCall(app, "conversations/get", conversationInput(chat), IMConversation.self, b)
            #expect(left.closed && left.latestSeq == 1)
            chat = try await imCall(app, "groups/update", groupChange(chat, action: "add", target: b.userID), IMConversation.self, a)
            _ = try await imCall(app, "messages/send", outgoing(chat, a), IMMessage.self, a)
            let history = try await imCall(app, "history", historyInput(chat), IMHistoryResponse.self, b)
            #expect(history.messages.map(\.serverSeq) == [3, 1])
            var continued = historyInput(chat); continued.beforeSeq = staleHistory.nextBeforeSeq
            continued.upperBoundSeq = staleHistory.upperBoundSeq; continued.boundaryRevision = staleHistory.boundaryRevision
            #expect(try errorCode(await send(app, .POST, "/v1/im/history", continued, token: b.accessToken)) == "HISTORY_BOUNDARY_CHANGED")
            var receipt = IMReceiptsRequest(); receipt.conversationID = chat.conversationID; receipt.messageUuid = first.messageUuid
            let details = try await imCall(app, "receipts", receipt, IMReceiptsResponse.self, a)
            #expect(details.summary.expectedCount == 1 && details.members.map(\.userID) == [b.userID])
            #expect(try errorCode(await send(app, .POST, "/v1/im/groups/update", groupChange(chat, action: "leave"), token: a.accessToken)) == "OWNER_TRANSFER_REQUIRED")
            chat = try await imCall(app, "groups/update", groupChange(chat, action: "transfer", target: b.userID), IMConversation.self, a)
            chat = try await imCall(app, "groups/update", groupChange(chat, action: "leave"), IMConversation.self, a)
            #expect(chat.closed)
            chat = try await imCall(app, "groups/update", groupChange(chat, action: "dissolve"), IMConversation.self, b)
            #expect(chat.closed && chat.members.allSatisfy { !$0.active })
            #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", outgoing(chat, b), token: b.accessToken)) == "CONVERSATION_CLOSED")
        }
    }
    @Test func readMergeReceiptSnapshotAndUnreadCorrections() async throws {
        try await withServer { app, fixture in
            let a = try await auth(app, name: "im_a"), b = try await auth(app, name: "im_b"), c = try await auth(app, name: "im_c")
            let chat = try await group(app, a, [b, c])
            let message = try await imCall(app, "messages/send", outgoing(chat, a), IMMessage.self, a)
            var input = IMReceiptsRequest(); input.conversationID = chat.conversationID; input.messageUuid = message.messageUuid; input.limit = 1
            let before = try await imCall(app, "receipts", input, IMReceiptsResponse.self, a)
            #expect(before.summary.expectedCount == 2 && before.summary.readCount == 0 && !before.complete)
            let read = try await imCall(app, "read", watermark(chat, through: 1), IMReadState.self, b)
            #expect(read.unreadCount == 0 && read.readThroughSeq == 1 && read.deliveredThroughSeq == 1)
            #expect(try await imCall(app, "read", watermark(chat, through: 0), IMReadState.self, b).readThroughSeq == 1)
            _ = try await imCall(app, "delivered", watermark(chat, through: 1), IMReadState.self, c)
            input.snapshotToken = before.snapshotToken; input.cursor = before.nextCursor
            let after = try await imCall(app, "receipts", input, IMReceiptsResponse.self, a)
            #expect(after.summary == before.summary && after.complete)
            input.snapshotToken = ""; input.cursor = ""
            let fresh = try await imCall(app, "receipts", input, IMReceiptsResponse.self, a)
            #expect(fresh.summary.deliveredCount == 2 && fresh.summary.readCount == 1)
            #expect(try errorCode(await send(app, .POST, "/v1/im/receipts", input, token: b.accessToken)) == "RECEIPT_FORBIDDEN")
            fixture.clock.advance(601)
            input.snapshotToken = before.snapshotToken; input.cursor = before.nextCursor
            #expect(try errorCode(await send(app, .POST, "/v1/im/receipts", input, token: a.accessToken)) == "SNAPSHOT_EXPIRED")
        }
    }
    @Test func revokeSanitizesHistoryEventsAndLostSendResponse() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "im_a"), b = try await auth(app, name: "im_b")
            let chat = try await direct(app, a, b)
            let input = outgoing(chat, a)
            let message = try await imCall(app, "messages/send", input, IMMessage.self, a)
            var revoke = IMRevokeRequest(); revoke.operationID = UUID().uuidString; revoke.conversationID = chat.conversationID; revoke.messageUuid = message.messageUuid
            #expect(try errorCode(await send(app, .POST, "/v1/im/messages/revoke", revoke, token: b.accessToken)) == "REVOKE_FORBIDDEN")
            let result = try await imCall(app, "messages/revoke", revoke, IMMessage.self, a)
            #expect(result.revoked && result.text.isEmpty && result.serverRevision == 2 && result.serverSeq == 1)
            let retry = try await imCall(app, "messages/send", input, IMMessage.self, a)
            #expect(retry.revoked && retry.text.isEmpty)
            let history = try await imCall(app, "history", historyInput(chat), IMHistoryResponse.self, b)
            #expect(history.messages.count == 1 && history.messages[0].text.isEmpty)
            let events = try await imCall(app, "events", IMEventsRequest(), IMEventsResponse.self, b)
            #expect(events.events.filter(\.hasMessage).allSatisfy { $0.message.revoked && $0.message.text.isEmpty })
            #expect(events.events.last?.conversation.readState.unreadCount == 0)
            #expect(try await imCall(app, "messages/revoke", revoke, IMMessage.self, a).serverRevision == 2)
        }
    }
    @Test func historyFixedUpperBoundAndPaginatedEvents() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "im_a"), b = try await auth(app, name: "im_b")
            let chat = try await direct(app, a, b)
            for _ in 0..<3 { _ = try await imCall(app, "messages/send", outgoing(chat, a), IMMessage.self, a) }
            let first = try await imCall(app, "history", historyInput(chat, limit: 2), IMHistoryResponse.self, b)
            #expect(first.messages.map(\.serverSeq) == [3, 2] && first.hasMore_p)
            _ = try await imCall(app, "messages/send", outgoing(chat, a), IMMessage.self, a)
            var request = historyInput(chat, limit: 2); request.beforeSeq = first.nextBeforeSeq
            request.upperBoundSeq = first.upperBoundSeq; request.boundaryRevision = first.boundaryRevision
            let second = try await imCall(app, "history", request, IMHistoryResponse.self, b)
            #expect(second.messages.map(\.serverSeq) == [1] && !second.hasMore_p && second.upperBoundSeq == 3)
            var eventInput = IMEventsRequest(); eventInput.limit = 2
            var positions: [Int64] = []
            while true {
                let page = try await imCall(app, "events", eventInput, IMEventsResponse.self, b)
                positions += page.events.map(\.position); eventInput.cursor = page.nextCursor; eventInput.epoch = page.epoch
                if !page.hasMore_p { break }
            }
            #expect(positions == [1, 2, 3, 4, 5])
            #expect(try await imCall(app, "events", eventInput, IMEventsResponse.self, b).events.isEmpty)
            #expect(try errorCode(await send(app, .POST, "/v1/im/events", eventInput, token: a.accessToken)) == "INVALID_CURSOR")
            eventInput.cursor += "x"
            #expect(try errorCode(await send(app, .POST, "/v1/im/events", eventInput, token: b.accessToken)) == "INVALID_CURSOR")
            eventInput = IMEventsRequest(); eventInput.epoch = "expired-epoch"
            #expect(try errorCode(await send(app, .POST, "/v1/im/events", eventInput, token: b.accessToken)) == "CURSOR_EXPIRED")
        }
    }
    @Test func fixedSnapshotIncludesClosedRelationsAndBaseline() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "im_a"), b = try await auth(app, name: "im_b"), c = try await auth(app, name: "im_c")
            _ = try await direct(app, a, b)
            var closed = try await group(app, a, [b])
            closed = try await imCall(app, "groups/update", groupChange(closed, action: "dissolve"), IMConversation.self, a)
            var input = IMSnapshotRequest(); input.limit = 1
            let first = try await imCall(app, "snapshot", input, IMSnapshotResponse.self, a)
            #expect(first.conversations.count == 1 && !first.complete && first.baselineCursor.isEmpty)
            _ = try await direct(app, a, c)
            input.snapshotToken = first.snapshotToken; input.cursor = first.nextCursor
            #expect(try errorCode(await send(app, .POST, "/v1/im/snapshot", input, token: b.accessToken)) == "SNAPSHOT_NOT_FOUND")
            let second = try await imCall(app, "snapshot", input, IMSnapshotResponse.self, a)
            #expect(second.complete && !second.baselineCursor.isEmpty)
            #expect((first.conversations + second.conversations).contains { $0.closed })
            var events = IMEventsRequest(); events.cursor = second.baselineCursor; events.epoch = second.epoch
            let delta = try await imCall(app, "events", events, IMEventsResponse.self, a)
            #expect(delta.events.count == 1 && delta.events[0].conversation.kind == "direct")
        }
    }
    @Test func restartEncryptionAndRetryAfterTokenRotation() async throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let app = try await fixture.app()
        let a: AuthResponse, b: AuthResponse, chat: IMConversation, request: IMSendRequest, message: IMMessage, renewed: AuthResponse, cursor: IMEventsResponse
        do {
            a = try await auth(app, name: "im_a"); b = try await auth(app, name: "im_b")
            chat = try await direct(app, a, b); request = outgoing(chat, a)
            message = try await imCall(app, "messages/send", request, IMMessage.self, a)
            cursor = try await imCall(app, "events", IMEventsRequest(), IMEventsResponse.self, b)
            renewed = try decode(AuthResponse.self, await send(app, .POST, "/v1/auth/refresh", refresh(a.refreshToken)))
            #expect(try await imCall(app, "messages/send", request, IMMessage.self, renewed) == message)
            for file in try FileManager.default.contentsOfDirectory(atPath: fixture.directory) where file.hasPrefix("server.sqlite") {
                let data = try Data(contentsOf: URL(fileURLWithPath: fixture.directory + "/" + file))
                #expect(data.range(of: Data(request.text.utf8)) == nil)
            }
        } catch { try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
        let reopened = try await fixture.app()
        do {
            #expect(try await imCall(reopened, "messages/send", request, IMMessage.self, renewed) == message)
            #expect(try await imCall(reopened, "history", historyInput(chat), IMHistoryResponse.self, b).messages.first == message)
            var input = IMEventsRequest(); input.cursor = cursor.nextCursor; input.epoch = cursor.epoch
            #expect(try await imCall(reopened, "events", input, IMEventsResponse.self, b).events.isEmpty)
            fixture.clock.advance(121)
            var revoke = IMRevokeRequest(); revoke.operationID = UUID().uuidString; revoke.conversationID = chat.conversationID; revoke.messageUuid = message.messageUuid
            #expect(try errorCode(await send(reopened, .POST, "/v1/im/messages/revoke", revoke, token: renewed.accessToken)) == "REVOKE_WINDOW_EXPIRED")
            fixture.clock.advance(481)
            #expect(try errorCode(await send(reopened, .POST, "/v1/im/messages/send", request, token: renewed.accessToken)) == "OPERATION_RESULT_EXPIRED")
        } catch { try await reopened.asyncShutdown(); throw error }
        try await reopened.asyncShutdown()
    }
    @Test func concurrentDistinctMessagesHaveContiguousSequence() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "im_a"), b = try await auth(app, name: "im_b")
            let chat = try await direct(app, a, b)
            let sequences = try await withThrowingTaskGroup(of: Int64.self) { tasks in
                for index in 0..<10 {
                    let input = outgoing(chat, a, text: "并发消息 \(index)")
                    tasks.addTask { try await imCall(app, "messages/send", input, IMMessage.self, a).serverSeq }
                }
                var result: [Int64] = []
                for try await value in tasks { result.append(value) }
                return result.sorted()
            }
            #expect(sequences == Array(1...10).map(Int64.init))
            let events = try await imCall(app, "events", IMEventsRequest(), IMEventsResponse.self, b)
            #expect(events.events.map(\.position) == Array(1...11).map(Int64.init))
        }
    }

    @Test func removedMemberMetadataAndBoundaryStayFrozen() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "im_a"), b = try await auth(app, name: "im_b")
            var chat = try await group(app, a, [b])
            _ = try await imCall(app, "messages/send", outgoing(chat, a), IMMessage.self, a)
            chat = try await imCall(app, "groups/update", groupChange(chat, action: "remove", target: b.userID), IMConversation.self, a)
            let closed = try await imCall(app, "conversations/get", conversationInput(chat), IMConversation.self, b)
            let checkpoint = try await imCall(app, "events", IMEventsRequest(), IMEventsResponse.self, b)
            var rename = groupChange(chat, action: "rename"); rename.title = "离开后不应看见的标题"
            _ = try await imCall(app, "groups/update", rename, IMConversation.self, a)
            let later = try await imCall(app, "conversations/get", conversationInput(chat), IMConversation.self, b)
            #expect(later.title == closed.title && later.serverRevision == closed.serverRevision)
            var request = historyInput(chat); request.beforeSeq = 2; request.upperBoundSeq = 1; request.boundaryRevision = closed.boundaryRevision
            #expect(try await imCall(app, "history", request, IMHistoryResponse.self, b).messages.count == 1)
            var events = IMEventsRequest(); events.cursor = checkpoint.nextCursor; events.epoch = checkpoint.epoch
            #expect(try await imCall(app, "events", events, IMEventsResponse.self, b).events.isEmpty)
        }
    }

    @Test func largePagesRespectByteBudgetWithoutSkippingMessages() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "im_a"), b = try await auth(app, name: "im_b")
            let chat = try await direct(app, a, b)
            for _ in 0..<52 {
                _ = try await imCall(app, "messages/send", outgoing(chat, a, text: String(repeating: "🐟", count: 16384)), IMMessage.self, a)
            }
            var request = historyInput(chat, limit: 100)
            var sequences: [Int64] = []
            while true {
                let result = try await imCall(app, "history", request, IMHistoryResponse.self, b)
                #expect(try result.serializedData().count < 4 * 1024 * 1024)
                sequences += result.messages.map(\.serverSeq)
                if !result.hasMore_p { break }
                request.beforeSeq = result.nextBeforeSeq; request.upperBoundSeq = result.upperBoundSeq; request.boundaryRevision = result.boundaryRevision
            }
            #expect(sequences == Array(1...52).reversed().map(Int64.init))
            var events = IMEventsRequest(); events.limit = 200
            var positions: [Int64] = []
            while true {
                let page = try await imCall(app, "events", events, IMEventsResponse.self, b)
                #expect(try page.serializedData().count < 4 * 1024 * 1024)
                positions += page.events.map(\.position)
                if !page.hasMore_p { break }
                events.cursor = page.nextCursor; events.epoch = page.epoch
            }
            #expect(positions == Array(1...53).map(Int64.init))
        }
    }

    @Test func ciphertextSubstitutionFailsWithoutAdvancingState() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "im_a"), b = try await auth(app, name: "im_b")
            let chat = try await direct(app, a, b)
            let first = try await imCall(app, "messages/send", outgoing(chat, a), IMMessage.self, a)
            let second = try await imCall(app, "messages/send", outgoing(chat, b), IMMessage.self, b)
            let one = try #require(await IMMessageRecord.find(UUID(uuidString: first.messageUuid), on: app.db))
            let two = try #require(await IMMessageRecord.find(UUID(uuidString: second.messageUuid), on: app.db))
            let original = one.payload; one.payload = two.payload; try await one.update(on: app.db)
            let attempted = watermark(chat, through: 1)
            let oldTail = try await IMEventRecord.query(on: app.db).count()
            // 水位写入后物化未读发现被篡改正文，整个事务（含水位和事件）应回滚。
            let failed = try await send(app, .POST, "/v1/im/delivered", attempted, token: b.accessToken)
            #expect(try errorCode(failed) == "INTERNAL_ERROR")
            #expect(try await IMMessageRecord.query(on: app.db).count() == 2)
            #expect(try await IMEventRecord.query(on: app.db).count() == oldTail)
            #expect(try await OperationRecord.find(UUID(uuidString: attempted.operationID), on: app.db) == nil)
            one.payload = original; try await one.update(on: app.db)
            #expect(try await imCall(app, "history", historyInput(chat), IMHistoryResponse.self, a).messages.count == 2)
            #expect(try await imCall(app, "conversations/get", conversationInput(chat), IMConversation.self, b).readState.deliveredThroughSeq == 0)
        }
    }

    @Test func existingAccountDatabaseMigratesWithoutLosingSessions() async throws {
        let fixture = Fixture(); defer { fixture.clean() }
        try FileManager.default.createDirectory(atPath: fixture.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let old = try await Application.make(.testing); old.logger.logLevel = .critical
        let existing: AuthResponse
        do {
            old.databases.use(.sqlite(.file(fixture.directory + "/server.sqlite")), as: .sqlite)
            old.migrations.add(CreateSchema()); try await old.autoMigrate()
            let crypto = try Cryptography(key: fixture.key, environment: "test")
            let marker = MetadataRecord(); marker.id = "key-check-v1"
            marker.value = try crypto.seal(Data("AzureFishServer".utf8), context: "metadata")
            try await marker.create(on: old.db)
            old.passwords.use(.bcrypt(cost: 4))
            let service = AccountService(crypto: crypto, dummyHash: "unused", clock: { fixture.clock.now() })
            old.post("v1", "auth", "register", use: service.register)
            existing = try await auth(old, name: "legacy_account")
        } catch { try await old.asyncShutdown(); throw error }
        try await old.asyncShutdown()
        let current = try await fixture.app()
        do {
            #expect(try decode(UserProfile.self, await me(current, existing.accessToken)).userID == existing.userID)
            let peer = try await auth(current, name: "new_peer")
            let chat = try await direct(current, existing, peer)
            #expect(try await imCall(current, "messages/send", outgoing(chat, existing), IMMessage.self, existing).serverSeq == 1)
            #expect(try await UserRecord.query(on: current.db).count() == 2)
        } catch { try await current.asyncShutdown(); throw error }
        try await current.asyncShutdown()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AZUREFISH_RUN_HTTP_SMOKE"] == "1"))
    func realSocketSmoke() async throws {
        try await withServer { app, _ in
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try #require(app.http.server.shared.localAddress?.port)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            process.arguments = [root.appendingPathComponent("Scripts/smoke-test.py").path]
            var environment = ProcessInfo.processInfo.environment; environment["AZUREFISH_SMOKE_PORT"] = String(port)
            process.environment = environment
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            await app.server.shutdown()
        }
    }

}
