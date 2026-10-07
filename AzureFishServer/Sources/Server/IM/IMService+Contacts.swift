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
        var state: ContactState = try decrypt(row.payload, context: "contact:" + row.requireID().uuidString)
        if state.sides == nil {
            state.sides = Dictionary(uniqueKeysWithValues: [row.firstUser, row.secondUser].map {
                ($0.uuidString, ContactSide(retained: state.status == "friend", revision: state.revision, updated: state.updated))
            })
            state.requestID = try row.requireID().uuidString.lowercased()
            state.requestStatus = state.status == "friend" || state.status == "deleted" ? "accepted" : state.status
            state.requestMessage = ""
            state.requestUpdated = state.updated
        }
        return state
    }
    func requireFriend(_ user: UUID, _ peer: UUID, db: any Database) async throws {
        guard let target = try await UserRecord.find(peer, on: db), try accounts.payload(target).deleted != true else { throw APIError(.forbidden, "CONTACT_UNAVAILABLE") }
        guard let row = try await contactRecord(user, peer, db: db) else { throw APIError(.forbidden, "FRIEND_REQUIRED") }
        let state = try contactState(row)
        guard let own = state.sides?[user.uuidString], let other = state.sides?[peer.uuidString] else {
            throw APIError(.forbidden, "FRIEND_REQUIRED")
        }
        guard !own.blocked && !other.blocked else { throw APIError(.forbidden, "CONTACT_UNAVAILABLE") }
        guard own.retained && other.retained else { throw APIError(.forbidden, "FRIEND_REQUIRED") }
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
        result.peer.avatarID = try accounts.payload(profile).avatarID ?? ""
        result.peer.deleted = try accounts.payload(profile).deleted == true
        result.state = "none"
        result.semanticsVersion = 2
        result.availableActions = user == peer ? [] : ["request", "block"]
        if let row = try await contactRecord(user, peer, db: db) {
            let value = try contactState(row)
            let own = value.sides![user.uuidString]!
            let other = value.sides![peer.uuidString]!
            result.relationshipID = try row.requireID().uuidString.lowercased()
            result.state = own.retained ? "friend" : value.requestStatus == "pending" ? "pending" : "deleted"
            result.requesterUserID = value.requester.uuidString.lowercased()
            result.revision = own.revision
            result.updatedAtMs = own.updated ?? value.updated
            result.isContact = own.retained
            result.remark = own.remark
            result.isBlocked = own.blocked
            result.requestID = value.requestID ?? ""
            result.requestState = value.requestStatus ?? ""
            result.requestMessage = value.requestMessage ?? ""
            result.requestUpdatedAtMs = value.requestUpdated ?? 0
            var actions = ["remark", own.blocked ? "unblock" : "block"]
            if own.retained { actions.append("delete") }
            if !own.blocked && !other.blocked {
                if own.retained && other.retained { actions.append("send") }
                else if value.requestStatus == "pending" {
                    actions += value.requester == user ? ["cancel"] : ["accept", "reject"]
                } else if !own.retained && other.retained { actions.append("restore") }
                else { actions.append("request") }
            }
            result.availableActions = actions
            if try accounts.payload(profile).deleted == true { result.availableActions = own.retained ? ["delete"] : [] }
        }
        return result
    }
    func contactGet(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(ContactGetRequest.self, from: req)
        let peer = try Validation.uuid(input.peerUserID, field: "peer_user_id")
        return try await read(req) { session, db in try await self.contactView(user: session.userID, peer: peer, db: db) }
    }
    func contactMutate(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(ContactMutationRequest.self, from: req)
        guard input.semanticsVersion == 2 else { throw APIError(.conflict, "CONTACT_CLIENT_UPDATE_REQUIRED") }
        let peer = try Validation.uuid(input.peerUserID, field: "peer_user_id")
        guard ["request", "accept", "reject", "cancel", "delete", "restore", "remark", "block", "unblock"].contains(input.action),
              input.expectedRevision >= 0 else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "action") }
        guard input.action == "remark" || input.remark.isEmpty,
              input.action == "request" || input.requestMessage.isEmpty else {
            throw APIError(.badRequest, "VALIDATION_FAILED", field: "action")
        }
        if !input.remark.isEmpty { try Validation.text(input.remark, field: "remark", max: 64) }
        if !input.requestMessage.isEmpty { try Validation.text(input.requestMessage, field: "request_message", max: 200) }
        return try await write(req, operation: input.operationID, bytes: bytes, name: "contact") { session, db in
            let user = session.userID
            guard peer != user else { throw APIError(.badRequest, "SELF_CONTACT") }
            guard let target = try await UserRecord.find(peer, on: db), try self.accounts.payload(target).deleted != true || input.action == "delete" else { throw APIError(.notFound, "USER_NOT_FOUND") }
            let existing = try await self.contactRecord(user, peer, db: db)
            let row = existing ?? ContactRecord()
            var state = try existing.map(self.contactState)
                ?? ContactState(status: "none", requester: user, revision: 0, updated: 0,
                                sides: [user.uuidString: ContactSide(retained: false, revision: 0),
                                        peer.uuidString: ContactSide(retained: false, revision: 0)])
            var own = state.sides![user.uuidString]!
            var other = state.sides![peer.uuidString]!
            // 交叉／重复申请只返回当前申请，不覆盖留言、申请身份或自动接受。
            if input.action == "request", !own.blocked && !other.blocked,
               state.requestStatus == "pending" || (own.retained && other.retained) {
                return try await self.contactView(user: user, peer: peer, db: db)
            }
            guard input.expectedRevision == own.revision else { throw APIError(.conflict, "CONTACT_VERSION_CONFLICT") }
            if ["request", "restore", "accept"].contains(input.action), own.blocked || other.blocked {
                throw APIError(.forbidden, "CONTACT_UNAVAILABLE")
            }
            if ["accept", "reject", "cancel"].contains(input.action),
               input.requestID != state.requestID { throw APIError(.conflict, "CONTACT_VERSION_CONFLICT") }
            if existing == nil {
                for member in [user, peer] {
                    let count = try await ContactRecord.query(on: db).group(.or) {
                        $0.filter(\.$firstUser == member).filter(\.$secondUser == member)
                    }.count()
                    guard count < 500 else { throw APIError(.conflict, "CONTACT_LIMIT") }
                }
                row.id = UUID(); row.pairKey = self.contactKey(user, peer)
                row.firstUser = user; row.secondUser = peer
            }
            switch input.action {
            case "request":
                try await self.accounts.limiter.check("contact-request:" + user.uuidString, limit: 20, now: self.accounts.clock())
                guard !other.retained else { throw APIError(.conflict, "CONTACT_ACTION_UNAVAILABLE") }
                state.requester = user
                state.requestID = input.operationID.lowercased()
                state.requestStatus = "pending"
                state.requestMessage = input.requestMessage
                state.requestUpdated = self.accounts.now
            case "accept", "reject":
                guard state.requestStatus == "pending", state.requester == peer else { throw APIError(.conflict, "CONTACT_ACTION_UNAVAILABLE") }
                state.requestStatus = input.action == "accept" ? "accepted" : "rejected"
                state.requestUpdated = self.accounts.now
                if input.action == "accept" { own.retained = true; other.retained = true }
            case "cancel":
                guard state.requestStatus == "pending", state.requester == user else { throw APIError(.conflict, "CONTACT_ACTION_UNAVAILABLE") }
                state.requestStatus = "cancelled"; state.requestUpdated = self.accounts.now
            case "delete":
                guard own.retained else { throw APIError(.conflict, "CONTACT_ACTION_UNAVAILABLE") }
                own.retained = false
            case "restore":
                guard !own.retained, other.retained, state.requestStatus != "pending" else { throw APIError(.conflict, "CONTACT_ACTION_UNAVAILABLE") }
                own.retained = true
            case "remark": own.remark = input.remark
            case "block", "unblock":
                own.blocked = input.action == "block"
                if own.blocked, state.requestStatus == "pending" {
                    state.requestStatus = "cancelled"; state.requestUpdated = self.accounts.now
                }
            default: throw APIError(.badRequest, "VALIDATION_FAILED")
            }
            state.revision += 1
            own.revision = state.revision; own.updated = self.accounts.now
            if input.action != "remark" { other.revision = state.revision; other.updated = self.accounts.now }
            state.sides = [user.uuidString: own, peer.uuidString: other]
            state.status = own.retained && other.retained ? "friend" : state.requestStatus == "pending" ? "pending" : "deleted"
            state.updated = self.accounts.now
            row.payload = try self.encrypt(state, context: "contact:" + row.requireID().uuidString)
            try await row.save(on: db)
            if input.action == "accept" {
                try await self.appendFriendshipNotice(relationship: row.requireID(), revision: state.revision,
                    requester: peer, accepter: user, db: db)
            }
            let recipients = input.action == "remark" ? [(user, peer)] : [(user, peer), (peer, user)]
            IMCommitSignals.current?.insert(recipients.map { $0.0 })
            for (recipient, otherID) in recipients {
                let event = ContactEventRecord(); event.id = UUID(); event.userID = recipient; event.peerID = otherID
                event.position = try await self.tail(recipient, db: db) + 1
                try await event.create(on: db)
            }
            return try await self.contactView(user: user, peer: peer, db: db)
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
        adjustUnread(message, state: &state, delta: 1)
        try await save(conversation, state, db: db)
        try await emit(conversation.requireID(), users: [requester, accepter], kind: "message", message: id, db: db)
    }

}
