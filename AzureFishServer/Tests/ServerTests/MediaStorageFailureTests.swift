@testable import Server
import Fluent
import Foundation
import Testing
import VaporTesting

/// 在存储边界注入 ENOSPC 等价失败，不填满开发者真实磁盘。
private struct FullMediaStore: MediaBlobStore {
    let base: any MediaBlobStore
    var root: URL { base.root }
    var work: URL { base.work }
    func io<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T { try await base.io(body) }
    func initialize() async throws { try await base.initialize() }
    func availableBytes() async throws -> Int64 { 0 }
    func put(_ data: Data, ticket: MediaResourceTicket, index: Int) async throws -> MediaChunk { throw APIError(.insufficientStorage, "MEDIA_STORAGE_UNAVAILABLE") }
    func read(_ chunk: MediaChunk, ticket: MediaResourceTicket) async throws -> Data { try await base.read(chunk, ticket: ticket) }
    func finish(_ chunks: [MediaChunk], ticket: MediaResourceTicket) async throws -> String { try await base.finish(chunks, ticket: ticket) }
    func manifest(_ ticket: MediaResourceTicket) async throws -> MediaManifest { try await base.manifest(ticket) }
    func discard(_ chunk: MediaChunk, ticket: MediaResourceTicket) async throws { try await base.discard(chunk, ticket: ticket) }
    func remove(_ resource: UUID) async throws { try await base.remove(resource) }
}
@Suite("媒体存储故障", .serialized)
struct MediaStorageFailureTests {
    @Test func diskCapacityAndWriteFailureKeepUploadRecoverable() async throws {
        try await withServer { app, _ in
            let media = app.storage[MediaServiceKey.self]!
            let failing = MediaService(accounts: media.accounts, im: media.im, blobs: FullMediaStore(base: media.blobs), limits: media.limits, worker: media.worker)
            failing.register(on: app.grouped("fault"))
            let a = try await auth(app, name: "full_a"), b = try await auth(app, name: "full_b"), chat = try await direct(app, a, b)
            var create = MediaCreateRequest(); create.operationID = UUID().uuidString; create.kind = "file"; create.conversationID = chat.conversationID
            var resource = MediaResourceInput(); resource.role = "original"; resource.filename = "a.bin"; resource.mimeType = "application/octet-stream"; resource.byteCount = 1; resource.sha256 = LocalMediaBlobStore.hash(Data([1])); create.resources = [resource]
            #expect(try errorCode(await send(app, .POST, "/fault/media/assets/create", create, token: a.accessToken)) == "MEDIA_STORAGE_UNAVAILABLE")
            #expect(try await MediaAssetRecord.query(on: app.db).count() == 0)
            let created = try decode(MediaAssetStatus.self, await send(app, .POST, "/v1/media/assets/create", create, token: a.accessToken))
            let upload = created.uploads[0]
            let headers: HTTPHeaders = ["Authorization": "Bearer " + a.accessToken, "Content-Type": "application/octet-stream", "X-Content-SHA256": resource.sha256]
            let failed = try await app.testing().sendRequest(.PUT, "/fault/media/uploads/\(upload.uploadID)/parts/0", headers: headers, body: ByteBuffer(bytes: [1]))
            #expect(failed.status == .insufficientStorage); #expect(try await MediaPartRecord.query(on: app.db).count() == 0)
            #expect(await !failing.leases.active(UUID(uuidString: created.assetID)!))
            let retry = try await app.testing().sendRequest(.PUT, "/v1/media/uploads/\(upload.uploadID)/parts/0", headers: headers, body: ByteBuffer(bytes: [1]))
            #expect(retry.status == .ok); #expect(try await MediaPartRecord.query(on: app.db).count() == 1)
        }
    }
}
