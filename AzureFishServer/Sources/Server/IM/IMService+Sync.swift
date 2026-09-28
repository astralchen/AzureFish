import Fluent
import Foundation
import SwiftProtobuf
import Vapor

extension IMService {
    func events(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(IMEventsRequest.self, from: req)
        let count = try limit(input.limit, max: 200, default: 100)
        guard input.epoch.isEmpty || input.epoch == epoch else { throw APIError(.conflict, "CURSOR_EXPIRED") }
        return try await read(req) { session, db in
            let position = try self.position(input.cursor, user: session.userID, resource: "events")
            let tail = try await self.tail(session.userID, db: db)
            guard position <= tail else { throw APIError(.badRequest, "INVALID_CURSOR") }
            let rows = try await IMEventRecord.query(on: db).filter(\.$userID == session.userID)
                .filter(\.$position > position).sort(\.$position).limit(count).all()
            let contactRows = try await ContactEventRecord.query(on: db).filter(\.$userID == session.userID)
                .filter(\.$position > position).sort(\.$position).limit(count).all()
            let positions = (rows.map(\.position) + contactRows.map(\.position)).sorted().prefix(count)
            let messageRows = Dictionary(uniqueKeysWithValues: rows.map { ($0.position, $0) })
            let relationshipRows = Dictionary(uniqueKeysWithValues: contactRows.map { ($0.position, $0) })
            var result = IMEventsResponse(); result.epoch = self.epoch
            result.ownProfileVersion = try await UserRecord.find(session.userID, on: db)?.version ?? 0
            result.baseCursor = try self.cursor(user: session.userID, resource: "events", position: position)
            var next = position
            var cache: [UUID: (IMConversationState, IMConversation)] = [:]
            var size = 0
            for eventPosition in positions {
                if let contact = relationshipRows[eventPosition] {
                    var event = IMEvent(); event.position = eventPosition; event.kind = "contact"
                    event.contact = try await self.contactView(user: session.userID, peer: contact.peerID, db: db)
                    let bytes = try event.serializedData().count
                    if size + bytes > 3 * 1024 * 1024 && !result.events.isEmpty { break }
                    result.events.append(event); size += bytes; next = eventPosition
                    continue
                }
                guard let row = messageRows[eventPosition] else { continue }
                let state: IMConversationState
                let view: IMConversation
                if let entry = cache[row.conversationID] { (state, view) = entry }
                else {
                    let (conversation, loaded) = try await self.load(row.conversationID.uuidString, user: session.userID, db: db)
                    state = loaded; view = try await self.view(conversation, state, user: session.userID, db: db)
                    cache[row.conversationID] = (state, view)
                }
                var event = IMEvent(); event.position = row.position; event.kind = row.kind; event.conversation = view
                if let messageID = row.messageID {
                    let message = try await self.visibleMessage(messageID, conversation: row.conversationID, state: state, user: session.userID, db: db)
                    event.message = try self.renderedMessage(message, state)
                }
                let bytes = try event.serializedData().count
                if size + bytes > 3 * 1024 * 1024 && !result.events.isEmpty { break }
                result.events.append(event); size += bytes; next = row.position
            }
            result.nextCursor = try self.cursor(user: session.userID, resource: "events", position: next)
            result.hasMore_p = next < tail; return result
        }
    }

    func snapshot(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(IMSnapshotRequest.self, from: req)
        let count = try limit(input.limit, max: 100, default: 50)
        return try await read(req) { session, db in
            let record: IMSnapshotRecord
            var full: IMSnapshotResponse
            if input.snapshotToken.isEmpty {
                guard input.cursor.isEmpty else { throw APIError(.badRequest, "INVALID_CURSOR") }
                full = IMSnapshotResponse(); full.epoch = self.epoch
                let memberships = try await IMMemberRecord.query(on: db).filter(\.$userID == session.userID).sort(\.$conversationID).all()
                for membership in memberships {
                    let (row, state) = try await self.load(membership.conversationID.uuidString, user: session.userID, db: db)
                    full.conversations.append(try await self.view(row, state, user: session.userID, db: db))
                }
                let relationships = try await ContactRecord.query(on: db).group(.or) {
                    $0.filter(\.$firstUser == session.userID).filter(\.$secondUser == session.userID)
                }.sort(\.$id).all()
                for relationship in relationships {
                    let peer = relationship.firstUser == session.userID ? relationship.secondUser : relationship.firstUser
                    full.contacts.append(try await self.contactView(user: session.userID, peer: peer, db: db))
                }
                full.baselineCursor = try await self.cursor(user: session.userID, resource: "events", position: self.tail(session.userID, db: db))
                record = try await self.storeSnapshot(full, user: session.userID, resource: "conversations", db: db)
            } else {
                record = try await self.loadSnapshot(input.snapshotToken, user: session.userID, resource: "conversations", db: db)
                full = try IMSnapshotResponse(serializedBytes: self.crypto.open(record.payload, context: "snapshot:" + record.requireID().uuidString))
            }
            let resource = "snapshot:" + (try record.requireID()).uuidString
            let offset = try self.position(input.cursor, user: session.userID, resource: resource)
            let total = full.conversations.count + full.contacts.count
            guard offset <= total else { throw APIError(.badRequest, "INVALID_CURSOR") }
            var result = IMSnapshotResponse(); result.snapshotToken = try record.requireID().uuidString.lowercased(); result.epoch = self.epoch
            var next = Int(offset), size = 0
            while next < total && result.conversations.count + result.contacts.count < count {
                let bytes = try next < full.conversations.count ? full.conversations[next].serializedData().count : full.contacts[next - full.conversations.count].serializedData().count
                if size + bytes > 3 * 1024 * 1024 && next > Int(offset) { break }
                if next < full.conversations.count { result.conversations.append(full.conversations[next]) }
                else { result.contacts.append(full.contacts[next - full.conversations.count]) }
                next += 1; size += bytes
            }
            result.complete = next == total
            if result.complete { result.baselineCursor = full.baselineCursor }
            else { result.nextCursor = try self.cursor(user: session.userID, resource: resource, position: Int64(next)) }
            return result
        }
    }

    func receipts(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(IMReceiptsRequest.self, from: req)
        let uuid = try Validation.uuid(input.messageUuid, field: "message_uuid")
        let count = try limit(input.limit, max: 100, default: 50)
        return try await read(req) { session, db in
            let (conversation, state) = try await self.load(input.conversationID, user: session.userID, db: db)
            let message = try await self.visibleMessage(uuid, conversation: conversation.requireID(), state: state, user: session.userID, db: db)
            // 仅发送者查询受众明细，成员不能枚举其他人的阅读习惯。
            guard try self.storedMessage(message).contentType != "system" else { throw APIError(.forbidden, "RECEIPT_FORBIDDEN") }
            guard try self.storedMessage(message).senderUserID == session.userID.uuidString.lowercased() else { throw APIError(.forbidden, "RECEIPT_FORBIDDEN") }
            let resource = "receipts:" + uuid.uuidString
            let record: IMSnapshotRecord
            var full: IMReceiptsResponse
            if input.snapshotToken.isEmpty {
                guard input.cursor.isEmpty else { throw APIError(.badRequest, "INVALID_CURSOR") }
                full = IMReceiptsResponse(); full.summary = try self.renderedMessage(message, state).receipt
                for user in try self.messageState(message).audience {
                    let member = state.members.first(where: { $0.user == user })!
                    var detail = IMReceiptDetail(); detail.userID = user.uuidString.lowercased()
                    detail.delivered = member.delivered >= message.sequence; detail.read = member.read >= message.sequence
                    full.members.append(detail)
                }
                full.members.sort { $0.userID < $1.userID }
                record = try await self.storeSnapshot(full, user: session.userID, resource: resource, db: db)
            } else {
                record = try await self.loadSnapshot(input.snapshotToken, user: session.userID, resource: resource, db: db)
                full = try IMReceiptsResponse(serializedBytes: self.crypto.open(record.payload, context: "snapshot:" + record.requireID().uuidString))
            }
            let pageResource = "snapshot:" + (try record.requireID()).uuidString
            let offset = try self.position(input.cursor, user: session.userID, resource: pageResource)
            guard offset <= full.members.count else { throw APIError(.badRequest, "INVALID_CURSOR") }
            let end = min(Int(offset) + count, full.members.count)
            var result = IMReceiptsResponse(); result.snapshotToken = try record.requireID().uuidString.lowercased()
            result.summary = full.summary; result.members = Array(full.members[Int(offset)..<end]); result.complete = end == full.members.count
            if !result.complete { result.nextCursor = try self.cursor(user: session.userID, resource: pageResource, position: Int64(end)) }
            return result
        }
    }

    private func storeSnapshot<M: Message>(_ value: M, user: UUID, resource: String, db: any Database) async throws -> IMSnapshotRecord {
        try await IMSnapshotRecord.query(on: db).filter(\.$expiresAt <= accounts.now).delete()
        guard try await IMSnapshotRecord.query(on: db).filter(\.$userID == user).count() < 16 else { throw APIError(.tooManyRequests, "SNAPSHOT_LIMIT") }
        let bytes = try value.serializedData()
        guard bytes.count <= 16 * 1024 * 1024 else { throw APIError(.conflict, "SNAPSHOT_TOO_LARGE") }
        let record = IMSnapshotRecord(); record.id = UUID(); record.userID = user; record.resource = resource
        record.expiresAt = accounts.now + 600_000
        record.payload = try crypto.seal(bytes, context: "snapshot:" + record.requireID().uuidString)
        try await record.create(on: db); return record
    }
    private func loadSnapshot(_ token: String, user: UUID, resource: String, db: any Database) async throws -> IMSnapshotRecord {
        guard let id = UUID(uuidString: token), let record = try await IMSnapshotRecord.find(id, on: db),
              record.userID == user, record.resource == resource else { throw APIError(.notFound, "SNAPSHOT_NOT_FOUND") }
        guard record.expiresAt > accounts.now else { throw APIError(.conflict, "SNAPSHOT_EXPIRED") }
        return record
    }
}
