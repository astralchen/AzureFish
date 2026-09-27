import Fluent
import Foundation
import SwiftProtobuf
import Vapor

extension IMService {
    func lookup(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(IMLookupUserRequest.self, from: req)
        let account = try Validation.account(input.accountName)
        return try await read(req) { session, db in
            try await self.accounts.limiter.check("lookup:" + session.userID.uuidString, limit: 20, now: self.accounts.clock())
            let digest = self.crypto.digest(Data(account.utf8), purpose: "account")
            guard let user = try await UserRecord.query(on: db).filter(\.$accountDigest == digest).first() else { throw APIError(.notFound, "USER_NOT_FOUND") }
            var result = IMPublicUser(); result.userID = try user.requireID().uuidString.lowercased()
            result.nickname = try self.accounts.payload(user).nickname; result.profileVersion = user.version; return result
        }
    }
    func resolve(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(IMResolveRequest.self, from: req)
        let peer = try Validation.uuid(input.peerUserID, field: "peer_user_id")
        return try await write(req, operation: input.operationID, bytes: bytes, name: "resolve") { session, db in
            guard peer != session.userID else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "peer_user_id") }
            guard try await UserRecord.find(peer, on: db) != nil else { throw APIError(.notFound, "USER_NOT_FOUND") }
            let pair = [peer.uuidString, session.userID.uuidString].sorted().joined(separator: ":")
            let key = self.crypto.digest(Data(pair.utf8), purpose: "im-pair")
            if let row = try await IMConversationRecord.query(on: db).filter(\.$pairKey == key).first() {
                let state: IMConversationState = try self.decrypt(row.payload, context: "conversation:" + row.requireID().uuidString)
                return try await self.view(row, state, user: session.userID, db: db)
            }
            return try await self.create(kind: "direct", title: "", owner: nil, members: [session.userID, peer], pair: key, user: session.userID, db: db)
        }
    }
    func createGroup(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(IMCreateGroupRequest.self, from: req)
        try Validation.text(input.title, field: "title", max: 64)
        let members = try input.memberUserIds.map { try Validation.uuid($0, field: "member_user_ids") }
        guard (1...99).contains(members.count), Set(members).count == members.count else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "member_user_ids") }
        return try await write(req, operation: input.operationID, bytes: bytes, name: "create-group") { session, db in
            guard !members.contains(session.userID) else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "member_user_ids") }
            for id in members {
                guard try await UserRecord.find(id, on: db) != nil else { throw APIError(.notFound, "USER_NOT_FOUND") }
            }
            return try await self.create(kind: "group", title: input.title, owner: session.userID, members: [session.userID] + members, pair: UUID().uuidString, user: session.userID, db: db)
        }
    }
    private func create(kind: String, title: String, owner: UUID?, members: [UUID], pair: String, user: UUID, db: any Database) async throws -> IMConversation {
        for member in members { try await checkConversationCapacity(member, db: db) }
        let row = IMConversationRecord(); row.id = UUID(); row.pairKey = pair
        let state = IMConversationState(kind: kind, title: title, owner: owner, members: members.map { IMMemberState(user: $0, intervals: [.init(joined: 1)]) })
        try await save(row, state, db: db)
        for member in members { try await indexMember(member, conversation: row.requireID(), db: db) }
        try await emit(row.requireID(), users: members, kind: "conversation", db: db)
        return try await view(row, state, user: user, db: db)
    }
    private func checkConversationCapacity(_ user: UUID, db: any Database) async throws {
        guard try await IMMemberRecord.query(on: db).filter(\.$userID == user).count() < 500 else { throw APIError(.conflict, "CONVERSATION_LIMIT") }
    }
    private func indexMember(_ user: UUID, conversation: UUID, db: any Database) async throws {
        let index = IMMemberRecord(); index.id = UUID(); index.userID = user; index.conversationID = conversation
        try await index.create(on: db)
    }
    func conversation(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(IMConversationRequest.self, from: req)
        return try await read(req) { session, db in
            let (row, state) = try await self.load(input.conversationID, user: session.userID, db: db)
            return try await self.view(row, state, user: session.userID, db: db)
        }
    }
    func updateGroup(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(IMUpdateGroupRequest.self, from: req)
        let actions = ["rename", "add", "remove", "leave", "transfer", "dissolve"]
        guard actions.contains(input.action), input.expectedRevision > 0,
              (input.action == "rename" || input.title.isEmpty),
              (["add", "remove", "transfer"].contains(input.action) || input.memberUserID.isEmpty) else {
            throw APIError(.badRequest, "VALIDATION_FAILED", field: "action")
        }
        if input.action == "rename" { try Validation.text(input.title, field: "title", max: 64) }
        let target = ["add", "remove", "transfer"].contains(input.action) ? try Validation.uuid(input.memberUserID, field: "member_user_id") : nil
        return try await write(req, operation: input.operationID, bytes: bytes, name: "update-group") { session, db in
            let (row, original) = try await self.load(input.conversationID, user: session.userID, db: db, active: true)
            var state = original
            guard state.kind == "group" else { throw APIError(.badRequest, "NOT_A_GROUP") }
            guard state.revision == input.expectedRevision else { throw APIError(.conflict, "CONVERSATION_VERSION_CONFLICT") }
            guard input.action == "leave" || state.owner == session.userID else { throw APIError(.forbidden, "OWNER_REQUIRED") }
            switch input.action {
            case "rename": state.title = input.title
            case "add":
                guard let target, try await UserRecord.find(target, on: db) != nil else { throw APIError(.notFound, "USER_NOT_FOUND") }
                if let index = state.members.firstIndex(where: { $0.user == target }) {
                    guard !state.members[index].active else { throw APIError(.conflict, "ALREADY_MEMBER") }
                    guard state.members[index].intervals.count < 100 else { throw APIError(.conflict, "MEMBERSHIP_LIMIT") }
                    state.members[index].intervals.append(.init(joined: state.latest + 1))
                    state.members[index].closedConversation = nil
                } else {
                    guard state.members.count < 100 else { throw APIError(.conflict, "MEMBERSHIP_LIMIT") }
                    try await self.checkConversationCapacity(target, db: db)
                    state.members.append(.init(user: target, intervals: [.init(joined: state.latest + 1)]))
                    try await self.indexMember(target, conversation: row.requireID(), db: db)
                }
                state.boundary += 1
            case "leave", "remove":
                let removed = input.action == "leave" ? session.userID : target!
                guard removed != state.owner else { throw APIError(.conflict, "OWNER_TRANSFER_REQUIRED") }
                guard let index = state.members.firstIndex(where: { $0.user == removed && $0.active }) else { throw APIError(.notFound, "MEMBER_NOT_FOUND") }
                state.members[index].intervals[state.members[index].intervals.count - 1].left = state.latest + 1
                state.boundary += 1
            case "transfer":
                guard let target, target != state.owner, state.members.contains(where: { $0.user == target && $0.active }) else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "member_user_id") }
                state.owner = target
            case "dissolve":
                state.dissolved = true
                for index in state.members.indices where state.members[index].active {
                    state.members[index].intervals[state.members[index].intervals.count - 1].left = state.latest + 1
                }
                state.boundary += 1
            default: throw APIError(.badRequest, "VALIDATION_FAILED", field: "action")
            }
            state.revision += 1; state.summaryRevision += 1
            // 离开时冻结可见资料，后续群名、群主和成员变化不泄露给旧成员。
            for index in state.members.indices where !state.members[index].active && state.members[index].closedConversation == nil {
                state.members[index].closedConversation = try await self.view(row, state, user: state.members[index].user, db: db).serializedData()
            }
            try await self.save(row, state, db: db)
            // 含离开成员，保证快照／增量显式表达关闭关系。
            try await self.emit(row.requireID(), users: original.members.filter(\.active).map(\.user) + state.members.filter(\.active).map(\.user), kind: "conversation", db: db)
            return try await self.view(row, state, user: session.userID, db: db)
        }
    }
}
