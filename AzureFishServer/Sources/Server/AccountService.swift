import Fluent
import Foundation
import SwiftProtobuf
import Vapor

/// 提供密码身份、可恢复刷新和当前账号资料；数据库事务由共享 gate 隔离。
final class AccountService: Sendable {
    let crypto: Cryptography
    let gate = DatabaseGate()
    let limiter = RateLimiter()
    let dummyHash: String
    let clock: @Sendable () -> Date
    private let accessLifetime: Int64 = 15 * 60 * 1000
    private let refreshLifetime: Int64 = 30 * 24 * 60 * 60 * 1000
    private let recoveryLifetime: Int64 = 10 * 60 * 1000

    init(crypto: Cryptography, dummyHash: String, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.crypto = crypto; self.dummyHash = dummyHash; self.clock = clock
    }
    var now: Int64 { Int64(clock().timeIntervalSince1970 * 1000) }

    func register(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(RegisterRequest.self, from: req)
        let operation = try Validation.uuid(input.operationID, field: "operation_id")
        let device = try Validation.uuid(input.deviceID, field: "device_id").uuidString.lowercased()
        let account = try Validation.account(input.accountName)
        try Validation.password(input.password)
        try Validation.text(input.nickname, field: "nickname", max: 64)
        let index = crypto.digest(Data(account.utf8), purpose: "account")
        try await limiter.check("account:" + index, limit: 10, now: clock())
        let result = try await gate.run {
            try await req.db.transaction { db -> Data in
                if let replay = try await self.replay(operation, scope: "register", bytes: bytes, db: db) { return replay }
                guard try await UserRecord.query(on: db).filter(\.$accountDigest == index).first() == nil else {
                    throw APIError(.conflict, "ACCOUNT_TAKEN", field: "account_name")
                }
                let hash = try await req.password.async.hash(input.password)
                let id = UUID()
                let payload = UserPayload(accountName: account, passwordHash: hash, nickname: input.nickname, bio: "", createdAt: self.now, updatedAt: self.now)
                let user = UserRecord(id: id, accountDigest: index, payload: try self.encrypt(payload, id: id), version: 1)
                try await user.create(on: db)
                let session = self.newSession(userID: id, device: device)
                let auth = try self.issue(session, user: user)
                try await session.create(on: db)
                let result = try auth.serializedData()
                try await self.record(operation, scope: "register", bytes: bytes, result: result, session: session, db: db)
                return result
            }
        }
        return raw(result, status: .created)
    }

    func login(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(LoginRequest.self, from: req)
        let operation = try Validation.uuid(input.operationID, field: "operation_id")
        let device = try Validation.uuid(input.deviceID, field: "device_id").uuidString.lowercased()
        let account = try Validation.account(input.accountName)
        try Validation.password(input.password)
        let index = crypto.digest(Data(account.utf8), purpose: "account")
        try await limiter.check("account:" + index, limit: 10, now: clock())
        let result = try await gate.run {
            try await req.db.transaction { db -> Data in
                if let replay = try await self.replay(operation, scope: "login", bytes: bytes, db: db) { return replay }
                let user = try await UserRecord.query(on: db).filter(\.$accountDigest == index).first()
                let hash = try user.map { try self.payload($0).passwordHash } ?? self.dummyHash
                let verified = try await req.password.async.verify(input.password, created: hash)
                guard verified, let user else { throw APIError(.unauthorized, "INVALID_CREDENTIALS") }
                let session = self.newSession(userID: try user.requireID(), device: device)
                let auth = try self.issue(session, user: user)
                try await session.create(on: db)
                let result = try auth.serializedData()
                try await self.record(operation, scope: "login", bytes: bytes, result: result, session: session, db: db)
                return result
            }
        }
        return raw(result)
    }

    func refresh(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(RefreshRequest.self, from: req)
        let operation = try Validation.uuid(input.operationID, field: "operation_id")
        guard input.refreshToken.utf8.count == 43 else { throw APIError(.unauthorized, "UNAUTHENTICATED") }
        let digest = crypto.digest(Data(input.refreshToken.utf8), purpose: "refresh")
        // 重放攻击必须先提交撤销事务，再向 HTTP 层抛错，不能被事务回滚恢复会话。
        let outcome: Result<Data, APIError> = try await gate.run {
            try await req.db.transaction { db -> Result<Data, APIError> in
                if let replay = try await self.replay(operation, scope: "refresh", bytes: bytes, db: db) { return .success(replay) }
                if let used = try await UsedRefreshRecord.query(on: db).filter(\.$digest == digest).first() {
                    if let session = try await SessionRecord.find(used.sessionID, on: db), session.refreshExpiry > self.now {
                        session.revoked = true
                        try await session.update(on: db)
                    }
                    return .failure(APIError(.unauthorized, "REFRESH_REPLAY"))
                }
                guard let session = try await SessionRecord.query(on: db).filter(\.$refreshDigest == digest).first(),
                      !session.revoked, session.refreshExpiry > self.now,
                      let user = try await UserRecord.find(session.userID, on: db) else {
                    throw APIError(.unauthorized, "UNAUTHENTICATED")
                }
                let used = UsedRefreshRecord()
                used.id = UUID(); used.digest = digest; used.sessionID = try session.requireID(); used.expiresAt = session.refreshExpiry
                try await used.create(on: db)
                session.generation += 1
                let auth = try self.issue(session, user: user)
                try await session.update(on: db)
                let result = try auth.serializedData()
                try await self.record(operation, scope: "refresh", bytes: bytes, result: result, session: session, db: db)
                return .success(result)
            }
        }
        return raw(try outcome.get())
    }

    func logout(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(LogoutRequest.self, from: req)
        let operation = try Validation.uuid(input.operationID, field: "operation_id")
        let result = try await gate.run {
            try await req.db.transaction { db -> Data in
                let session = try await self.authenticate(req, db: db, allowRevoked: true)
                let scope = "logout:" + (try session.requireID()).uuidString
                if let replay = try await self.replay(operation, scope: scope, bytes: bytes, db: db, requireActive: false) { return replay }
                guard !session.revoked else { throw APIError(.unauthorized, "UNAUTHENTICATED") }
                session.revoked = true
                try await session.update(on: db)
                let data = try EmptyResponse().serializedData()
                try await self.record(operation, scope: scope, bytes: bytes, result: data, session: session, db: db)
                return data
            }
        }
        return raw(result)
    }

    func me(_ req: Request) async throws -> Response {
        let data = try await gate.run {
            let session = try await self.authenticate(req, db: req.db)
            guard let user = try await UserRecord.find(session.userID, on: req.db) else { throw APIError(.unauthorized, "UNAUTHENTICATED") }
            return try self.profile(user).serializedData()
        }
        return raw(data)
    }

    func update(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(UpdateProfileRequest.self, from: req)
        let operation = try Validation.uuid(input.operationID, field: "operation_id")
        guard input.expectedProfileVersion > 0 else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "expected_profile_version") }
        guard input.hasNickname || input.hasBio else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "profile") }
        if input.hasNickname { try Validation.text(input.nickname, field: "nickname", max: 64) }
        if input.hasBio { try Validation.text(input.bio, field: "bio", max: 500, allowEmpty: true) }
        let data = try await gate.run {
            try await req.db.transaction { db -> Data in
                let session = try await self.authenticate(req, db: db)
                let scope = "profile:" + (try session.requireID()).uuidString
                if let replay = try await self.replay(operation, scope: scope, bytes: bytes, db: db) { return replay }
                guard let user = try await UserRecord.find(session.userID, on: db) else { throw APIError(.unauthorized, "UNAUTHENTICATED") }
                guard user.version == input.expectedProfileVersion else { throw APIError(.conflict, "PROFILE_VERSION_CONFLICT", field: "expected_profile_version") }
                var payload = try self.payload(user)
                if input.hasNickname { payload.nickname = input.nickname }
                if input.hasBio { payload.bio = input.bio }
                payload.updatedAt = self.now
                user.version += 1
                user.payload = try self.encrypt(payload, id: user.requireID())
                try await user.update(on: db)
                let result = try self.profile(user).serializedData()
                try await self.record(operation, scope: scope, bytes: bytes, result: result, session: session, db: db)
                return result
            }
        }
        return raw(data)
    }

    private func authenticate(_ req: Request, db: any Database, allowRevoked: Bool = false) async throws -> SessionRecord {
        guard let token = req.headers.bearerAuthorization?.token, token.utf8.count == 43 else { throw APIError(.unauthorized, "UNAUTHENTICATED") }
        let digest = crypto.digest(Data(token.utf8), purpose: "access")
        guard let session = try await SessionRecord.query(on: db).filter(\.$accessDigest == digest).first(),
              session.accessExpiry > now, session.refreshExpiry > now, allowRevoked || !session.revoked else {
            throw APIError(.unauthorized, "UNAUTHENTICATED")
        }
        return session
    }

    private func newSession(userID: UUID, device: String) -> SessionRecord {
        let session = SessionRecord()
        session.id = UUID(); session.userID = userID; session.deviceID = device
        session.generation = 1; session.revoked = false; session.refreshExpiry = now + refreshLifetime
        return session
    }

    private func issue(_ session: SessionRecord, user: UserRecord) throws -> AuthResponse {
        let access = Cryptography.randomToken(), refresh = Cryptography.randomToken()
        session.accessDigest = crypto.digest(Data(access.utf8), purpose: "access")
        session.refreshDigest = crypto.digest(Data(refresh.utf8), purpose: "refresh")
        session.accessExpiry = min(now + accessLifetime, session.refreshExpiry)
        var result = AuthResponse()
        result.environmentID = crypto.environment; result.userID = session.userID.uuidString.lowercased()
        result.sessionID = try session.requireID().uuidString.lowercased(); result.deviceID = session.deviceID
        result.accessToken = access; result.refreshToken = refresh
        result.accessExpiresAtMs = session.accessExpiry; result.refreshExpiresAtMs = session.refreshExpiry
        result.refreshGeneration = session.generation; result.profile = try profile(user)
        return result
    }

    private func payload(_ user: UserRecord) throws -> UserPayload {
        try JSONDecoder().decode(UserPayload.self, from: crypto.open(user.payload, context: "user:" + user.requireID().uuidString))
    }
    private func encrypt(_ payload: UserPayload, id: UUID) throws -> String {
        try crypto.seal(JSONEncoder().encode(payload), context: "user:" + id.uuidString)
    }
    private func profile(_ user: UserRecord) throws -> UserProfile {
        let payload = try payload(user)
        var profile = UserProfile()
        profile.userID = try user.requireID().uuidString.lowercased(); profile.accountName = payload.accountName
        profile.nickname = payload.nickname; profile.bio = payload.bio; profile.profileVersion = user.version
        profile.createdAtMs = payload.createdAt; profile.updatedAtMs = payload.updatedAt
        return profile
    }

    private func replay(_ id: UUID, scope: String, bytes: Data, db: any Database, requireActive: Bool = true) async throws -> Data? {
        guard let op = try await OperationRecord.find(id, on: db) else { return nil }
        guard op.scope == scope, op.fingerprint == crypto.digest(bytes, purpose: scope) else { throw APIError(.conflict, "OPERATION_CONFLICT", field: "operation_id") }
        guard let session = try await SessionRecord.find(op.sessionID, on: db), session.refreshExpiry > now,
              !requireActive || !session.revoked else { throw APIError(.unauthorized, "UNAUTHENTICATED") }
        if ["refresh", "register", "login"].contains(scope), session.generation != op.generation {
            throw APIError(.conflict, scope == "refresh" ? "REFRESH_SUPERSEDED" : "AUTH_ATTEMPT_EXPIRED")
        }
        guard op.resultExpiry > now else {
            throw APIError(.conflict, ["register", "login", "refresh"].contains(scope) ? "AUTH_ATTEMPT_EXPIRED" : "OPERATION_RESULT_EXPIRED")
        }
        return try crypto.open(op.result, context: "operation:" + id.uuidString)
    }

    private func record(_ id: UUID, scope: String, bytes: Data, result: Data, session: SessionRecord, db: any Database) async throws {
        let op = OperationRecord()
        op.id = id; op.scope = scope; op.fingerprint = crypto.digest(bytes, purpose: scope)
        op.sessionID = try session.requireID(); op.generation = session.generation
        op.result = try crypto.seal(result, context: "operation:" + id.uuidString)
        op.resultExpiry = min(now + recoveryLifetime, session.refreshExpiry)
        op.retentionExpiry = session.refreshExpiry
        try await op.create(on: db)
    }

    private func raw(_ bytes: Data, status: HTTPResponseStatus = .ok) -> Response {
        Response(status: status, headers: ["Content-Type": "application/protobuf", "Cache-Control": "no-store"], body: .init(data: bytes))
    }
}
