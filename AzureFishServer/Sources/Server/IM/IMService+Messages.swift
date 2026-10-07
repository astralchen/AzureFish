import Fluent
import Foundation
import SwiftProtobuf
import Vapor

extension IMService {
    func send(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(IMSendRequest.self, from: req)
        let uuid = try Validation.uuid(input.messageUuid, field: "message_uuid")
        let client = try Validation.uuid(input.clientMessageID, field: "client_message_id")
        let device = try Validation.uuid(input.deviceID, field: "device_id").uuidString.lowercased()
        guard ["text", "link", "media_group", "audio", "file"].contains(input.contentType), input.contentSchemaVersion == 1 else { throw APIError(.badRequest, "UNSUPPORTED_CONTENT") }
        if ["text", "link"].contains(input.contentType) {
            // 聊天正文保留 emoji ZWJ、RTL 格式字符及用户换行；账号资料仍使用原校验。
            guard input.text.count <= 16384,
                  !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !input.text.unicodeScalars.contains(where: {
                      $0.properties.generalCategory == .control && ![9, 10, 13].contains($0.value)
                  }) else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "text") }
            guard input.assetIds.isEmpty else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "asset_ids") }
            guard input.text.utf8.count <= 65536 else { throw APIError(.payloadTooLarge, "PAYLOAD_TOO_LARGE") }
        } else {
            guard input.text.isEmpty, !input.assetIds.isEmpty, input.assetIds.count <= 20 else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "asset_ids") }
        }
        if input.contentType == "text" {
            guard input.linkURL.isEmpty, input.textRuns.count <= 16384,
                  input.textRuns.allSatisfy({ !$0.text.isEmpty && $0.style & ~UInt32(15) == 0 }),
                  input.textRuns.isEmpty || input.textRuns.map(\.text).joined() == input.text else {
                throw APIError(.badRequest, "VALIDATION_FAILED", field: "text_runs")
            }
        } else if input.contentType == "link" {
            guard input.textRuns.isEmpty, input.text == input.linkURL,
                  let url = URL(string: input.linkURL),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  !(url.host ?? "").isEmpty else {
                throw APIError(.badRequest, "VALIDATION_FAILED", field: "link_url")
            }
        } else {
            guard input.textRuns.isEmpty, input.linkURL.isEmpty else {
                throw APIError(.badRequest, "VALIDATION_FAILED", field: "content_type")
            }
        }
        var canonical = input; canonical.operationID = ""
        canonical.messageUuid = uuid.uuidString.lowercased(); canonical.clientMessageID = client.uuidString.lowercased()
        canonical.deviceID = device
        canonical.assetIds = try input.assetIds.map { try Validation.uuid($0, field: "asset_ids").uuidString.lowercased() }
        canonical.conversationID = try Validation.uuid(input.conversationID, field: "conversation_id").uuidString.lowercased()
        let fingerprint = crypto.digest(try canonical.serializedData(), purpose: "im-message")
        return try await write(req, operation: input.operationID, bytes: bytes, name: "send") { session, db in
            guard device == session.deviceID else { throw APIError(.forbidden, "DEVICE_MISMATCH") }
            let (conversation, original) = try await self.load(input.conversationID, user: session.userID, db: db, active: true)
            var state = original
            let key = self.crypto.digest(Data((session.userID.uuidString + ":" + client.uuidString).utf8), purpose: "im-client-message")
            let existingUUID = try await IMMessageRecord.find(uuid, on: db)
            let existingClient = try await IMMessageRecord.query(on: db).filter(\.$clientKey == key).first()
            if let existing = existingUUID ?? existingClient {
                guard existing.id == uuid, existing.clientKey == key, existing.conversationID == conversation.id,
                      try self.messageState(existing).fingerprint == fingerprint else { throw APIError(.conflict, "MESSAGE_ID_CONFLICT") }
                return try self.renderedMessage(existing, state)
            }
            try await self.requireSending(user: session.userID, state: state, db: db)
            guard state.latest < 100_000 else { throw APIError(.conflict, "MESSAGE_LIMIT") }
            state.latest += 1; state.summaryRevision += 1
            var result = IMMessage(); result.conversationID = try conversation.requireID().uuidString.lowercased()
            result.messageUuid = uuid.uuidString.lowercased(); result.clientMessageID = client.uuidString.lowercased()
            result.serverMessageID = UUID().uuidString.lowercased(); result.senderUserID = session.userID.uuidString.lowercased()
            result.deviceID = device; result.serverSeq = state.latest; result.serverCreatedAtMs = self.accounts.now
            result.serverRevision = 1; result.contentType = input.contentType; result.contentSchemaVersion = input.contentSchemaVersion; result.text = input.text
            result.textRuns = input.textRuns; result.linkURL = input.linkURL
            let audience = state.members.filter { $0.active && $0.user != session.userID }.map(\.user)
            let row = IMMessageRecord(); row.id = uuid; row.conversationID = try conversation.requireID()
            row.sequence = state.latest; row.clientKey = key
            row.payload = try self.encrypt(IMMessageState(envelope: result.serializedData(), audience: audience, fingerprint: fingerprint), context: "message:" + uuid.uuidString)
            try await row.create(on: db)
            if !["text", "link"].contains(input.contentType) {
                guard let media = self.media else { throw APIError(.serviceUnavailable, "MEDIA_UNAVAILABLE") }
                result.assets = try await media.attach(input.assetIds, kind: input.contentType, conversation: conversation.requireID(), message: uuid, user: session.userID, db: db)
                row.payload = try self.encrypt(IMMessageState(envelope: result.serializedData(), audience: audience, fingerprint: fingerprint), context: "message:" + uuid.uuidString)
                try await row.update(on: db)
            }
            self.adjustUnread(result, state: &state, delta: 1)
            try await self.save(conversation, state, db: db)
            try await self.emit(conversation.requireID(), users: audience + [session.userID], kind: "message", message: uuid, db: db)
            return try self.renderedMessage(row, state)
        }
    }
    func revoke(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(IMRevokeRequest.self, from: req)
        let uuid = try Validation.uuid(input.messageUuid, field: "message_uuid")
        return try await write(req, operation: input.operationID, bytes: bytes, name: "revoke") { session, db in
            let (conversation, original) = try await self.load(input.conversationID, user: session.userID, db: db)
            var state = original
            let row = try await self.visibleMessage(uuid, conversation: conversation.requireID(), state: state, user: session.userID, db: db)
            var stored = try self.messageState(row)
            var message = try IMMessage(serializedBytes: stored.envelope)
            guard message.contentType != "system" else { throw APIError(.forbidden, "REVOKE_FORBIDDEN") }
            guard message.senderUserID == session.userID.uuidString.lowercased() else { throw APIError(.forbidden, "REVOKE_FORBIDDEN") }
            if !message.revoked {
                guard self.accounts.now <= message.serverCreatedAtMs + 120_000 else { throw APIError(.conflict, "REVOKE_WINDOW_EXPIRED") }
                self.adjustUnread(message, state: &state, delta: -1)
                message.revoked = true; message.text = ""; message.textRuns = []; message.linkURL = ""; message.assets = []; message.serverRevision += 1
                try await self.media?.detach(message: uuid, db: db)
                stored.envelope = try message.serializedData()
                row.payload = try self.encrypt(stored, context: "message:" + uuid.uuidString)
                state.summaryRevision += 1
                try await row.update(on: db); try await self.save(conversation, state, db: db)
                try await self.emit(conversation.requireID(), users: stored.audience + [session.userID], kind: "message", message: uuid, db: db)
            }
            return try self.renderedMessage(row, state)
        }
    }
    func visibleMessage(_ id: UUID, conversation: UUID, state: IMConversationState, user: UUID, db: any Database) async throws -> IMMessageRecord {
        guard let row = try await IMMessageRecord.find(id, on: db), row.conversationID == conversation,
              let member = state.members.first(where: { $0.user == user }), member.sees(row.sequence) else { throw APIError(.notFound, "MESSAGE_NOT_FOUND") }
        return row
    }
    func markRead(_ req: Request) async throws -> Response { try await watermark(req, reading: true) }
    func markDelivered(_ req: Request) async throws -> Response { try await watermark(req, reading: false) }
    private func watermark(_ req: Request, reading: Bool) async throws -> Response {
        let (input, bytes) = try requestMessage(IMWatermarkRequest.self, from: req)
        return try await write(req, operation: input.operationID, bytes: bytes, name: reading ? "read" : "delivered") { session, db in
            let (row, original) = try await self.load(input.conversationID, user: session.userID, db: db)
            var state = original
            let index = state.members.firstIndex(where: { $0.user == session.userID })!
            guard input.throughSeq >= 0, input.throughSeq <= state.members[index].upperBound(state.latest) else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "through_seq") }
            // 水位回复继续验证原有未读正文的认证状态，篡改不能因投影命中而被掩盖。
            // 计数与列表读取使用投影，完整性检查保留在水位写入事务中。
            _ = try await self.readDelta(row, member: state.members[index], through: state.members[index].upperBound(state.latest), latest: state.latest, db: db)
            let oldRead = state.members[index].read, oldDelivered = state.members[index].delivered
            if reading, input.throughSeq > oldRead {
                let count = try await self.readDelta(row, member: state.members[index], through: input.throughSeq, latest: state.latest, db: db)
                state.members[index].unread!.count = max(0, state.members[index].unread!.count - count)
                state.members[index].read = input.throughSeq
            }
            state.members[index].delivered = max(oldDelivered, input.throughSeq)
            if oldRead != state.members[index].read || oldDelivered != state.members[index].delivered {
                state.summaryRevision += 1
                try await self.save(row, state, db: db)
                try await self.emit(row.requireID(), users: state.members.map(\.user), kind: reading ? "read" : "receipt", db: db)
            }
            return try await self.view(row, state, user: session.userID, db: db).readState
        }
    }
    func history(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(IMHistoryRequest.self, from: req)
        let count = try limit(input.limit, max: 100, default: 50)
        guard input.beforeSeq >= 0, input.upperBoundSeq >= 0, input.boundaryRevision >= 0 else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "before_seq") }
        return try await read(req) { session, db in
            let (conversation, state) = try await self.load(input.conversationID, user: session.userID, db: db)
            let member = state.members.first(where: { $0.user == session.userID })!
            let boundary = try member.closedConversation.map { try IMConversation(serializedBytes: $0).boundaryRevision } ?? state.boundary
            let initial = input.beforeSeq == 0 && input.upperBoundSeq == 0 && input.boundaryRevision == 0
            guard initial || input.boundaryRevision == boundary else { throw APIError(.conflict, "HISTORY_BOUNDARY_CHANGED") }
            let upper = initial ? member.upperBound(state.latest) : input.upperBoundSeq
            let before = initial ? upper + 1 : input.beforeSeq
            guard upper <= member.upperBound(state.latest), before > 0, before <= upper + 1 else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "before_seq") }
            // 扫描量有界；无权查看的序号也推进覆盖区间，避免空页死循环。
            let rows = try await IMMessageRecord.query(on: db).filter(\.$conversationID == conversation.requireID())
                .filter(\.$sequence >= (member.intervals.first?.joined ?? 1)).filter(\.$sequence < before).filter(\.$sequence <= upper).sort(\.$sequence, .descending).limit(count).all()
            var response = IMHistoryResponse(); response.upperBoundSeq = upper; response.boundaryRevision = boundary
            response.earliestAvailableSeq = member.intervals.first?.joined ?? 1
            var next = before
            for row in rows {
                if member.sees(row.sequence) { response.messages.append(try self.renderedMessage(row, state)) }
                next = row.sequence
                if try response.serializedData().count > 3 * 1024 * 1024 { response.messages.removeLast(); next = row.sequence + 1; break }
            }
            response.nextBeforeSeq = next
            response.hasMore_p = next > response.earliestAvailableSeq && !rows.isEmpty
            if next < before { response.coveredFromSeq = next; response.coveredThroughSeq = before - 1 }
            return response
        }
    }
}
