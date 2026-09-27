import Crypto
import Fluent
import Foundation
import SwiftProtobuf
import Vapor

struct MediaServiceKey: StorageKey { typealias Value = MediaService }
/// 有界字节请求租约；回收必须等到持有该附件的 IO 和处理任务退出。
actor MediaLeases {
    struct Lease: Sendable { let user: UUID; let asset: UUID; let part: String?; let transfer: Bool }
    private var values: [UUID: Lease] = [:]
    func acquire(user: UUID, asset: UUID, part: String? = nil, transfer: Bool = true, limits: MediaLimits) throws -> UUID {
        if transfer {
            let active = values.values.filter(\.transfer)
            guard active.count < limits.instanceConcurrency, active.filter({ $0.user == user }).count < limits.accountConcurrency else { throw APIError(.tooManyRequests, "MEDIA_CONCURRENCY_LIMIT") }
        }
        guard part == nil || !values.values.contains(where: { $0.part == part }) else { throw APIError(.conflict, "PART_BUSY") }
        let id = UUID(); values[id] = Lease(user: user, asset: asset, part: part, transfer: transfer); return id
    }
    func release(_ id: UUID) { values.removeValue(forKey: id) }
    func active(_ asset: UUID) -> Bool { values.values.contains { $0.asset == asset } }
}

/// 协调媒体元数据、短事务与独立字节 IO；普通账号和 IM 继续共享原 gate。
final class MediaService: Sendable {
    let accounts: AccountService
    let im: IMService
    let blobs: any MediaBlobStore
    let limits: MediaLimits
    let worker: String
    let leases = MediaLeases()
    let runtime = MediaRuntime()
    var crypto: Cryptography { accounts.crypto }
    init(accounts: AccountService, im: IMService, blobs: any MediaBlobStore, limits: MediaLimits, worker: String) {
        self.accounts = accounts; self.im = im; self.blobs = blobs; self.limits = limits; self.worker = worker
    }
    func register(on routes: any RoutesBuilder) {
        let media = routes.grouped("media")
        media.get("capabilities", use: capabilities)
        media.post("assets", "create", use: create)
        media.post("assets", "status", use: status)
        media.post("assets", "complete", use: complete)
        media.post("assets", "cancel", use: cancel)
        media.on(.PUT, "uploads", ":upload", "parts", ":index", body: .stream, use: upload)
        media.post("resources", "authorize", use: authorize)
        media.get("resources", ":resource", "content", use: download)
    }
    func assetState(_ row: MediaAssetRecord) throws -> MediaAssetState { try im.decrypt(row.payload, context: "media-asset:" + row.requireID().uuidString) }
    func resourceState(_ row: MediaResourceRecord) throws -> MediaResourceState { try im.decrypt(row.payload, context: "media-resource:" + row.requireID().uuidString) }
    func save(_ row: MediaAssetRecord, _ state: MediaAssetState, db: any Database) async throws {
        row.payload = try im.encrypt(state, context: "media-asset:" + row.requireID().uuidString); try await row.save(on: db)
    }
    func save(_ row: MediaResourceRecord, _ state: MediaResourceState, db: any Database) async throws {
        row.payload = try im.encrypt(state, context: "media-resource:" + row.requireID().uuidString); try await row.save(on: db)
    }
    func owned(_ id: UUID, user: UUID, db: any Database) async throws -> MediaAssetRecord {
        guard let row = try await MediaAssetRecord.find(id, on: db), row.ownerID == user else { throw APIError(.notFound, "MEDIA_NOT_FOUND") }; return row
    }
    func effectiveState(_ row: MediaAssetRecord) -> String {
        if !["deleted", "cancelled", "expired"].contains(row.state), row.expiresAt > 0, row.expiresAt <= accounts.now { return "expired" }
        return row.state
    }
    func ticket(_ resource: MediaResourceRecord, asset: MediaAssetRecord) throws -> MediaResourceTicket {
        guard let wrapped = resource.wrappedKey else { throw APIError(.internalServerError, "MEDIA_KEY_UNAVAILABLE") }
        do {
            return try MediaResourceTicket(id: resource.requireID(), asset: asset.requireID(), owner: asset.ownerID, generation: asset.generation,
                key: crypto.unwrapMediaKey(wrapped, resource: resource.requireID()), state: resourceState(resource))
        } catch { throw APIError(.internalServerError, "MEDIA_KEY_UNAVAILABLE") }
    }
    func statusValue(_ row: MediaAssetRecord, db: any Database) async throws -> MediaAssetStatus {
        var value = MediaAssetStatus(); value.assetID = try row.requireID().uuidString.lowercased(); value.state = effectiveState(row)
        value.expiresAtMs = row.expiresAt
        let state = try assetState(row); value.failureCode = state.failure
        if value.state == "ready", let metadata = state.metadata { value.asset = try MediaAsset(serializedBytes: metadata) }
        if ["uploading", "queued", "processing", "ready", "failed"].contains(value.state) {
            let resources = try await MediaResourceRecord.query(on: db).filter(\.$assetID == row.requireID()).sort(\.$id).all()
            for resource in resources {
                guard let uploadID = resource.uploadID else { continue }
                let info = try resourceState(resource)
                var progress = MediaUploadProgress(); progress.resourceID = try resource.requireID().uuidString.lowercased()
                progress.uploadID = uploadID.uuidString.lowercased(); progress.role = info.role; progress.partCount = Int32((info.bytes + Int64(MediaLimits.chunk) - 1) / Int64(MediaLimits.chunk))
                progress.completedParts = try await MediaPartRecord.query(on: db).filter(\.$resourceID == resource.requireID()).sort(\.$index).all().map { Int32($0.index) }
                value.uploads.append(progress)
            }
        }
        return value
    }
    func mutate(_ req: Request, operation: String, bytes: Data, name: String,
                _ body: @escaping @Sendable (SessionRecord, any Database) async throws -> MediaAssetRecord) async throws -> Response {
        let id = try Validation.uuid(operation, field: "operation_id")
        return try await im.read(req) { session, db in
            let scope = "media:" + name + ":" + session.userID.uuidString
            let row: MediaAssetRecord
            if let operation = try await OperationRecord.find(id, on: db) {
                guard operation.scope == scope, operation.fingerprint == self.crypto.digest(bytes, purpose: scope) else { throw APIError(.conflict, "OPERATION_CONFLICT", field: "operation_id") }
                let result = try self.crypto.open(operation.result, context: "operation:" + id.uuidString)
                let identity = try MediaAssetRequest(serializedBytes: result)
                row = try await self.owned(Validation.uuid(identity.assetID, field: "asset_id"), user: session.userID, db: db)
            } else {
                row = try await body(session, db)
                var identity = MediaAssetRequest(); identity.assetID = try row.requireID().uuidString.lowercased()
                try await self.accounts.record(id, scope: scope, bytes: bytes, result: identity.serializedData(), session: session, db: db)
            }
            return try await self.statusValue(row, db: db)
        }
    }
    func enqueue(_ asset: MediaAssetRecord, kind: String, due: Int64, db: any Database) async throws {
        let existing = try await MediaJobRecord.query(on: db).filter(\.$assetID == asset.requireID()).filter(\.$kind == kind).first()
        let job = existing ?? MediaJobRecord()
        if existing == nil { job.id = UUID() }
        job.assetID = try asset.requireID(); job.kind = kind; job.generation = asset.generation; job.dueAt = due; job.state = "queued"
        try await job.save(on: db)
    }
    static func validDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}
