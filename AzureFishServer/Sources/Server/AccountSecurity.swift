import Fluent
import Foundation
import ImageIO
import SwiftProtobuf
import Vapor

/// 再次认证凭据只保存摘要；事务消费与业务变更一起提交。
final class ReauthenticationRecord: Model, @unchecked Sendable {
    static let schema = "account_reauthentication"
    @ID(key: .id) var id: UUID?
    @Field(key: "digest") var digest: String
    @Field(key: "session_id") var sessionID: UUID
    @Field(key: "action") var action: String
    @Field(key: "expires_at") var expiresAt: Int64
    @Field(key: "consumed") var consumed: Bool
    init() {}
}
struct CreateAccountSecuritySchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ReauthenticationRecord.schema).id()
            .field("digest", .string, .required).unique(on: "digest")
            .field("session_id", .uuid, .required, .references("sessions", "id"))
            .field("action", .string, .required).field("expires_at", .int64, .required)
            .field("consumed", .bool, .required).create()
    }
    func revert(on db: any Database) async throws { try await db.schema(ReauthenticationRecord.schema).delete() }
}

extension AccountService {
    func registerSecurity(on routes: RoutesBuilder, im: IMService) {
        routes.post("auth", "reauthenticate", use: reauthenticate)
        routes.get("me", "security") { req async throws -> Response in
            let data = try await self.gate.run {
                let session = try await self.authenticate(req, db: req.db)
                var result = AccountSecurityStatus(); result.passwordConfigured = true
                result.ownedGroups = try await self.ownedGroups(session.userID, im: im, db: req.db)
                return try result.serializedData()
            }
            return self.raw(data)
        }
        for action in ["change_password", "logout_all", "delete_account"] {
            routes.post("me", "security", PathComponent(stringLiteral: action)) { req async throws -> Response in
                try await im.committing { try await self.securityAction(req, action: action, im: im) }
            }
        }
        routes.on(.POST, "me", "avatar", body: .collect(maxSize: "260kb")) { req async throws -> Response in
            try await im.committing { try await self.updateAvatar(req, im: im) }
        }
        routes.get("users", ":user", "avatar", use: avatar)
    }

    func reauthenticate(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(ReauthenticateRequest.self, from: req)
        let id = try Validation.uuid(input.operationID, field: "operation_id")
        guard ["change_password", "logout_all", "delete_account"].contains(input.action) else {
            throw APIError(.badRequest, "VALIDATION_FAILED", field: "action")
        }
        try Validation.password(input.password)
        let data = try await gate.run {
            try await req.db.transaction { db in
                let session = try await self.authenticate(req, db: db)
                let scope = "reauth:" + (try session.requireID()).uuidString
                if let replay = try await self.replay(id, scope: scope, bytes: bytes, db: db) { return replay }
                try await self.limiter.check(scope, limit: 10, now: self.clock())
                guard let user = try await UserRecord.find(session.userID, on: db),
                      try await req.password.async.verify(input.password, created: self.payload(user).passwordHash) else {
                    throw APIError(.forbidden, "INVALID_CREDENTIALS", field: "password")
                }
                let token = Cryptography.randomToken()
                let row = ReauthenticationRecord(); row.id = UUID()
                row.digest = self.crypto.digest(Data(token.utf8), purpose: "reauth")
                row.sessionID = try session.requireID(); row.action = input.action
                row.expiresAt = self.now + 300_000; row.consumed = false
                try await row.create(on: db)
                var result = ReauthenticateResponse(); result.token = token; result.expiresAtMs = row.expiresAt
                let data = try result.serializedData()
                try await self.record(id, scope: scope, bytes: bytes, result: data, session: session, db: db)
                return data
            }
        }
        return raw(data)
    }

    func ownedGroups(_ user: UUID, im: IMService, db: any Database) async throws -> [IMConversation] {
        var result: [IMConversation] = []
        for member in try await IMMemberRecord.query(on: db).filter(\.$userID == user).all() {
            guard let row = try await IMConversationRecord.find(member.conversationID, on: db) else { continue }
            let state: IMConversationState = try im.decrypt(row.payload, context: "conversation:" + row.requireID().uuidString)
            if state.kind == "group", state.owner == user, !state.dissolved {
                result.append(try await im.view(row, state, user: user, db: db))
            }
        }
        return result
    }

    func securityAction(_ req: Request, action: String, im: IMService) async throws -> Response {
        let (input, bytes) = try requestMessage(AccountSecurityRequest.self, from: req)
        let id = try Validation.uuid(input.operationID, field: "operation_id")
        if action == "change_password" { try Validation.password(input.newPassword) }
        else if !input.newPassword.isEmpty { throw APIError(.badRequest, "VALIDATION_FAILED", field: "new_password") }
        let data = try await gate.run {
            try await req.db.transaction { db in
                // 仅原会话、原动作、原字节可在撤销之后恢复；不能用此入口执行新动作。
                let session = try await self.authenticate(req, db: db, allowRevoked: true, allowExpired: true)
                let scope = action + ":" + (try session.requireID()).uuidString
                if let replay = try await self.replay(id, scope: scope, bytes: bytes, db: db, requireActive: false) { return replay }
                guard !session.revoked, session.accessExpiry > self.now, let user = try await UserRecord.find(session.userID, on: db) else {
                    throw APIError(.unauthorized, "UNAUTHENTICATED")
                }
                let digest = self.crypto.digest(Data(input.reauthToken.utf8), purpose: "reauth")
                guard let proof = try await ReauthenticationRecord.query(on: db).filter(\.$digest == digest).first(),
                      proof.sessionID == session.id, proof.action == action, !proof.consumed, proof.expiresAt > self.now else {
                    throw APIError(.forbidden, "REAUTH_REQUIRED")
                }
                var value = try self.payload(user)
                if action == "delete_account" {
                    guard try await self.ownedGroups(session.userID, im: im, db: db).isEmpty else {
                        throw APIError(.conflict, "OWNER_TRANSFER_REQUIRED")
                    }
                    value = UserPayload(accountName: "deleted_" + session.userID.uuidString.lowercased(),
                        passwordHash: self.dummyHash, nickname: "Deleted user", bio: "", createdAt: value.createdAt,
                        updatedAt: self.now, deleted: true)
                    // 保留不可逆身份墓碑与账号摘要，禁止旧账号名被重新注册冒用。
                    let marker = MetadataRecord(); marker.id = "account-delete:" + session.userID.uuidString
                    marker.value = try self.crypto.seal(Data(), context: marker.id!)
                    try await marker.create(on: db)
                } else if action == "change_password" {
                    value.passwordHash = try await req.password.async.hash(input.newPassword)
                    value.updatedAt = self.now
                }
                user.version += 1; user.payload = try self.encrypt(value, id: user.requireID())
                try await user.update(on: db)
                proof.consumed = true; try await proof.update(on: db)
                for row in try await SessionRecord.query(on: db).filter(\.$userID == session.userID).all() {
                    row.revoked = true; try await row.update(on: db)
                }
                let result = try EmptyResponse().serializedData()
                try await self.record(id, scope: scope, bytes: bytes, result: result, session: session, db: db)

                return result
            }
        }
        if action == "delete_account" {
            // 停用和恢复日志已提交，清理失败仍返回受理；启动恢复继续执行。
            try? await gate.run { try await self.recoverDeletions(im: im, db: req.db) }
        }
        return raw(data, status: action == "delete_account" ? .accepted : .ok)
    }

    /// 清除账号私有投影，保留其他参与者仍有权访问的消息和媒体引用。
    func finishDeletion(_ user: UUID, im: IMService, db: any Database) async throws {
        let deleted = try await UserRecord.find(user, on: db)
        for membership in try await IMMemberRecord.query(on: db).filter(\.$userID == user).all() {
            guard let row = try await IMConversationRecord.find(membership.conversationID, on: db) else { continue }
            var state: IMConversationState = try im.decrypt(row.payload, context: "conversation:" + row.requireID().uuidString)
            if let index = state.members.firstIndex(where: { $0.user == user }) {
                if state.members[index].active {
                    state.members[index].intervals[state.members[index].intervals.count - 1].left = state.latest + 1
                }
                state.members[index].closedConversation = nil
                state.members[index].read = 0; state.members[index].delivered = 0
                state.members[index].unread = nil
                state.revision += 1; state.boundary += 1
                var closedViewers: [UUID] = []
                // 已退群成员仍保留历史边界，但注销身份不能继续展示旧资料快照。
                for i in state.members.indices {
                    guard let bytes = state.members[i].closedConversation else { continue }
                    var snapshot = try IMConversation(serializedBytes: bytes)
                    for j in snapshot.members.indices where snapshot.members[j].userID == user.uuidString.lowercased() {
                        snapshot.members[j].profile.nickname = "Deleted user"
                        snapshot.members[j].profile.avatarID = ""
                        snapshot.members[j].profile.deleted = true
                        snapshot.members[j].profile.profileVersion = deleted?.version ?? snapshot.members[j].profile.profileVersion + 1
                    }
                    snapshot.serverRevision = state.revision
                    state.members[i].closedConversation = try snapshot.serializedData()
                    closedViewers.append(state.members[i].user)
                }
                try await im.save(row, state, db: db)
                try await im.emit(row.requireID(), users: closedViewers, kind: "conversation", db: db)
            }
        }
        for row in try await ContactRecord.query(on: db).group(.or, { $0.filter(\.$firstUser == user).filter(\.$secondUser == user) }).all() {
            var state = try im.contactState(row)
            state.sides?[user.uuidString] = ContactSide(retained: false, revision: state.revision + 1)
            state.requestMessage = ""; state.requestStatus = "cancelled"; state.status = "deleted"
            row.payload = try im.encrypt(state, context: "contact:" + row.requireID().uuidString)
            try await row.update(on: db)
        }
        for asset in try await MediaAssetRecord.query(on: db).filter(\.$ownerID == user).all() {
            if try await MediaReferenceRecord.query(on: db).filter(\.$assetID == asset.requireID()).count() == 0 {
                asset.expiresAt = now; try await asset.update(on: db)
            }
        }
        try await IMSnapshotRecord.query(on: db).filter(\.$userID == user).delete()
        for session in try await SessionRecord.query(on: db).filter(\.$userID == user).all() {
            let id = try session.requireID()
            // 仅保留删除结果的最小恢复记录，移除包含旧资料或认证响应的私有结果。
            for operation in try await OperationRecord.query(on: db).filter(\.$sessionID == id).all()
                where operation.scope != "delete_account:" + id.uuidString {
                try await operation.delete(on: db)
            }
            try await ReauthenticationRecord.query(on: db).filter(\.$sessionID == id).delete()
        }
        try await im.publicProfileChanged(user, db: db)
        try await IMEventRecord.query(on: db).filter(\.$userID == user).delete()
        try await MetadataRecord.find("account-delete:" + user.uuidString, on: db)?.delete(on: db)
    }

    func recoverDeletions(im: IMService, db: any Database) async throws {
        for marker in try await MetadataRecord.query(on: db).all() {
            guard let id = marker.id, id.hasPrefix("account-delete:"), let user = UUID(uuidString: String(id.dropFirst(15))) else { continue }
            _ = try crypto.open(marker.value, context: id)
            try await db.transaction { db in try await self.finishDeletion(user, im: im, db: db) }
        }
    }

    func updateAvatar(_ req: Request, im: IMService) async throws -> Response {
        let (input, bytes) = try requestMessage(UpdateAvatarRequest.self, from: req)
        let id = try Validation.uuid(input.operationID, field: "operation_id")
        if !input.jpeg.isEmpty {
            guard input.jpeg.count <= 256 * 1024,
                  let source = CGImageSourceCreateWithData(input.jpeg as CFData, nil),
                  CGImageSourceGetType(source) as String? == "public.jpeg",
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == 512,
                  properties[kCGImagePropertyPixelHeight] as? Int == 512,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw APIError(.badRequest, "VALIDATION_FAILED", field: "jpeg")
            }
        }
        let data = try await gate.run {
            try await req.db.transaction { db in
                let session = try await self.authenticate(req, db: db)
                let scope = "avatar:" + (try session.requireID()).uuidString
                if let replay = try await self.replay(id, scope: scope, bytes: bytes, db: db) { return replay }
                guard let user = try await UserRecord.find(session.userID, on: db) else { throw APIError(.unauthorized, "UNAUTHENTICATED") }
                guard user.version == input.expectedProfileVersion else { throw APIError(.conflict, "PROFILE_VERSION_CONFLICT") }
                var value = try self.payload(user)
                value.avatarJPEG = input.jpeg.isEmpty ? nil : input.jpeg
                value.avatarID = input.jpeg.isEmpty ? nil : UUID().uuidString.lowercased()
                value.updatedAt = self.now; user.version += 1
                user.payload = try self.encrypt(value, id: user.requireID()); try await user.update(on: db)
                try await im.publicProfileChanged(session.userID, db: db)
                let result = try self.profile(user).serializedData()
                try await self.record(id, scope: scope, bytes: bytes, result: result, session: session, db: db)
                return result
            }
        }
        return raw(data)
    }

    func avatar(_ req: Request) async throws -> Response {
        let peer = try Validation.uuid(req.parameters.get("user") ?? "", field: "user_id")
        let data = try await gate.run {
            let session = try await self.authenticate(req, db: req.db)
            if session.userID != peer {
                let contact = try await ContactRecord.query(on: req.db).group(.or) {
                    $0.group(.and) { $0.filter(\.$firstUser == peer).filter(\.$secondUser == session.userID) }
                    $0.group(.and) { $0.filter(\.$firstUser == session.userID).filter(\.$secondUser == peer) }
                }.count() > 0
                let own = try await IMMemberRecord.query(on: req.db).filter(\.$userID == session.userID).all().map(\.conversationID)
                let shared = try await IMMemberRecord.query(on: req.db).filter(\.$userID == peer).filter(\.$conversationID ~~ own).count() > 0
                guard contact || shared else { throw APIError(.notFound, "USER_NOT_FOUND") }
            }
            guard let user = try await UserRecord.find(peer, on: req.db) else { throw APIError(.notFound, "USER_NOT_FOUND") }
            let value = try self.payload(user)
            var result = AvatarResponse(); result.avatarID = value.avatarID ?? ""; result.jpeg = value.avatarJPEG ?? Data()
            return try result.serializedData()
        }
        return raw(data)
    }
}
