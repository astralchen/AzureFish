import Fluent
import Foundation
import SwiftProtobuf
import Vapor

extension IMService {
    func contactKey(_ user: UUID, _ peer: UUID) -> String {
        crypto.digest(
            Data([user.uuidString, peer.uuidString].sorted().joined(separator: ":").utf8), purpose: "contact-pair")
    }
    func contactRecord(_ user: UUID, _ peer: UUID, db: any Database) async throws -> ContactRecord? {
        try await ContactRecord.query(on: db).filter(\.$pairKey == contactKey(user, peer)).first()
    }
    func contactState(_ row: ContactRecord) throws -> ContactState {
        try decrypt(row.payload, context: "contact:" + row.requireID().uuidString)
    }
    func requireFriend(_ user: UUID, _ peer: UUID, db: any Database) async throws {
        guard let row = try await contactRecord(user, peer, db: db), try contactState(row).status == "friend" else {
            throw APIError(.forbidden, "FRIEND_REQUIRED")
        }
    }
    func requireSending(user: UUID, state: IMConversationState, db: any Database) async throws {
        if state.kind == "direct", let peer = state.members.first(where: { $0.user != user }) {
            try await requireFriend(user, peer.user, db: db)
        }
    }
    func contactView(user: UUID, peer: UUID, db: any Database) async throws -> ContactRelationship {
        guard let profile = try await UserRecord.find(peer, on: db) else { throw APIError(.notFound, "USER_NOT_FOUND") }
        var result = ContactRelationship()
        result.peer.userID = peer.uuidString.lowercased()
        result.peer.nickname = try accounts.payload(profile).nickname
        result.peer.profileVersion = profile.version
        result.state = "none"
        if let row = try await contactRecord(user, peer, db: db) {
            let value = try contactState(row)
            result.relationshipID = try row.requireID().uuidString.lowercased()
            result.state = value.status
            result.requesterUserID = value.requester.uuidString.lowercased()
            result.revision = value.revision
            result.updatedAtMs = value.updated
        }
        return result
    }
    func contactGet(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(ContactGetRequest.self, from: req)
        let peer = try Validation.uuid(input.peerUserID, field: "peer_user_id")
        return try await read(req) { session, db in try await self.contactView(user: session.userID, peer: peer, db: db)
        }
    }
    func contactMutate(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(ContactMutationRequest.self, from: req)
        let peer = try Validation.uuid(input.peerUserID, field: "peer_user_id")
        guard ["request", "accept", "reject", "cancel", "delete"].contains(input.action), input.expectedRevision >= 0
        else {
            throw APIError(.badRequest, "VALIDATION_FAILED", field: "action")
        }
        return try await write(req, operation: input.operationID, bytes: bytes, name: "contact") { session, db in
            guard peer != session.userID else { throw APIError(.badRequest, "SELF_CONTACT") }
            guard try await UserRecord.find(peer, on: db) != nil else { throw APIError(.notFound, "USER_NOT_FOUND") }
            let existing = try await self.contactRecord(session.userID, peer, db: db)
            let row = existing ?? ContactRecord()
            var state =
                try existing.map(self.contactState)
                ?? ContactState(status: "none", requester: session.userID, revision: 0, updated: 0)
            // 交叉申请只展示现有申请，不自动接受，也不改写原申请人。
            if input.action == "request", ["pending", "friend"].contains(state.status) {
                return try await self.contactView(user: session.userID, peer: peer, db: db)
            }
            guard input.expectedRevision == state.revision else {
                throw APIError(.conflict, "CONTACT_VERSION_CONFLICT")
            }
            switch input.action {
            case "request":
                try await self.accounts.limiter.check(
                    "contact-request:" + session.userID.uuidString, limit: 20, now: self.accounts.clock())
                for user in [session.userID, peer] {
                    let count = try await ContactRecord.query(on: db).group(.or) {
                        $0.filter(\.$firstUser == user).filter(\.$secondUser == user)
                    }.count()
                    guard existing != nil || count < 500 else { throw APIError(.conflict, "CONTACT_LIMIT") }
                }
                state.status = "pending"
                state.requester = session.userID
            case "accept", "reject":
                guard state.status == "pending", state.requester == peer else {
                    throw APIError(.conflict, "CONTACT_ACTION_UNAVAILABLE")
                }
                state.status = input.action == "accept" ? "friend" : "rejected"
            case "cancel":
                guard state.status == "pending", state.requester == session.userID else {
                    throw APIError(.conflict, "CONTACT_ACTION_UNAVAILABLE")
                }
                state.status = "cancelled"
            case "delete":
                guard state.status == "friend" else { throw APIError(.conflict, "CONTACT_ACTION_UNAVAILABLE") }
                state.status = "deleted"
            default: throw APIError(.badRequest, "VALIDATION_FAILED")
            }
            if existing == nil {
                row.id = UUID()
                row.pairKey = self.contactKey(session.userID, peer)
                row.firstUser = session.userID
                row.secondUser = peer
            }
            state.revision += 1
            state.updated = self.accounts.now
            row.payload = try self.encrypt(state, context: "contact:" + row.requireID().uuidString)
            try await row.save(on: db)
            if input.action == "accept" {
                try await self.appendFriendshipNotice(relationship: row.requireID(), revision: state.revision,
                    requester: peer, accepter: session.userID, db: db)
            }
            for (user, other) in [(session.userID, peer), (peer, session.userID)] {
                let event = ContactEventRecord()
                event.id = UUID()
                event.userID = user
                event.peerID = other
                event.position = try await self.tail(user, db: db) + 1
                try await event.create(on: db)
            }
            return try await self.contactView(user: session.userID, peer: peer, db: db)
        }
    }
    /// 与好友关系同事务提交系统提示；唯一键隔离每次重新添加关系。
    func appendFriendshipNotice(relationship: UUID, revision: Int64, requester: UUID,
                               accepter: UUID, db: any Database) async throws {
        let key = crypto.digest(Data("\(relationship.uuidString):\(revision)".utf8), purpose: "im-friendship-notice")
        if try await IMMessageRecord.query(on: db).filter(\.$clientKey == key).first() != nil { return }
        let chat = try await resolveDirect(user: accepter, peer: requester, db: db)
        let (conversation, original) = try await load(chat.conversationID, user: accepter, db: db)
        var state = original
        guard state.latest < 100_000 else { throw APIError(.conflict, "MESSAGE_LIMIT") }
        state.latest += 1
        state.summaryRevision += 1
        let id = UUID()
        var message = IMMessage()
        message.conversationID = chat.conversationID
        message.messageUuid = id.uuidString.lowercased()
        message.serverMessageID = message.messageUuid
        message.serverSeq = state.latest
        message.serverCreatedAtMs = accounts.now
        message.serverRevision = 1
        message.contentType = "system"
        message.contentSchemaVersion = 1
        message.systemEvent.kind = "friendship_accepted"
        message.systemEvent.relationshipID = relationship.uuidString.lowercased()
        message.systemEvent.relationshipRevision = revision
        message.systemEvent.requesterUserID = requester.uuidString.lowercased()
        message.systemEvent.accepterUserID = accepter.uuidString.lowercased()
        let record = IMMessageRecord()
        record.id = id
        record.conversationID = try conversation.requireID()
        record.sequence = state.latest
        record.clientKey = key
        record.payload = try encrypt(IMMessageState(envelope: message.serializedData(), audience: [], fingerprint: key),
                                    context: "message:" + id.uuidString)
        try await record.create(on: db)
        try await save(conversation, state, db: db)
        try await emit(conversation.requireID(), users: [requester, accepter], kind: "message", message: id, db: db)
    }

}
