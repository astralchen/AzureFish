@testable import Server
import Crypto
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("媒体密文格式与恢复", .serialized)
struct MediaStorageTests {
    @Test func authenticatedChunksAndManifestRejectSubstitution() async throws {
        try await withServer { app, _ in
            let store = app.storage[MediaServiceKey.self]!.blobs
            let data = Data(repeating: 91, count: MediaLimits.chunk) + Data("final".utf8)
            var ticket = MediaResourceTicket(id: UUID(), asset: UUID(), owner: UUID(), generation: 1, key: Data(repeating: 31, count: 32), state: .init(role: "original", filename: "test.bin", mime: "application/octet-stream", bytes: Int64(data.count), sha256: LocalMediaBlobStore.hash(data)))
            let a = try await store.put(Data(data.prefix(MediaLimits.chunk)), ticket: ticket, index: 0)
            let b = try await store.put(Data(data.suffix(5)), ticket: ticket, index: 1)
            ticket.state.manifest = try await store.finish([a, b], ticket: ticket)
            #expect(try await store.manifest(ticket).chunks == [a, b])
            #expect(try await store.read(b, ticket: ticket) == data.suffix(5))
            var wrong = ticket; wrong.owner = UUID()
            await #expect(throws: (any Error).self) { try await store.read(a, ticket: wrong) }
            wrong = ticket; wrong.key = Data(repeating: 32, count: 32)
            await #expect(throws: (any Error).self) { try await store.manifest(wrong) }
            wrong = ticket; wrong.state.role = "cover"
            await #expect(throws: (any Error).self) { try await store.read(a, ticket: wrong) }
            await #expect(throws: (any Error).self) { try await store.finish([b, a], ticket: ticket) }
            let url = store.root.appendingPathComponent(ticket.id.uuidString.lowercased()).appendingPathComponent(b.filename)
            let original = try Data(contentsOf: url)
            try original.dropLast().write(to: url)
            await #expect(throws: (any Error).self) { try await store.read(b, ticket: ticket) }
            try original.write(to: url)
            let firstURL = url.deletingLastPathComponent().appendingPathComponent(a.filename)
            try Data(contentsOf: firstURL).write(to: url)
            await #expect(throws: (any Error).self) { try await store.read(b, ticket: ticket) }
        }
    }
    @Test func rangeAndConcurrencyLimits() async throws {
        #expect(try MediaByteRange.parse("bytes=2-4", ifRange: nil, etag: "x", size: 10).start == 2)
        #expect(try MediaByteRange.parse("bytes=-30", ifRange: nil, etag: "x", size: 10).end == 9)
        #expect(try MediaByteRange.parse("bytes=2-4", ifRange: "other", etag: "x", size: 10).partial == false)
        for range in ["bytes=1-0", "bytes=10-", "bytes=-0", "bytes=0-1,3-4", "bytes=x-", "bytes=+1-2"] {
            #expect(throws: APIError.self) { try MediaByteRange.parse(range, ifRange: nil, etag: "x", size: 10) }
        }
        let leases = MediaLeases(), user = UUID(), asset = UUID()
        var ids: [UUID] = []
        for _ in 0..<4 { ids.append(try await leases.acquire(user: user, asset: asset, limits: .init())) }
        await #expect(throws: APIError.self) { try await leases.acquire(user: user, asset: asset, limits: .init()) }
        for id in ids { await leases.release(id) }
        #expect(await !leases.active(asset))
    }
    @Test func resumeAfterRestartAndFreshLogin() async throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let first = try await fixture.app()
        var created = MediaAssetStatus(); var account = AuthResponse(); var input = MediaCreateRequest()
        do {
            account = try await auth(first, name: "restart_media")
            let peer = try await auth(first, name: "restart_peer"), chat = try await direct(first, account, peer)
            input.operationID = UUID().uuidString; input.conversationID = chat.conversationID; input.kind = "file"
            var resource = MediaResourceInput(); resource.role = "original"; resource.filename = "data.bin"; resource.mimeType = "application/octet-stream"
            resource.byteCount = 7; resource.sha256 = LocalMediaBlobStore.hash(Data("restart".utf8)); input.resources = [resource]
            created = try decode(MediaAssetStatus.self, await send(first, .POST, "/v1/media/assets/create", input, token: account.accessToken))
            let upload = created.uploads[0]
            let response = try await first.testing().sendRequest(.PUT, "/v1/media/uploads/\(upload.uploadID)/parts/0", headers: ["Authorization": "Bearer " + account.accessToken, "Content-Type": "application/octet-stream", "X-Content-SHA256": resource.sha256], body: ByteBuffer(string: "restart"))
            #expect(response.status == .ok)
            let media = first.storage[MediaServiceKey.self]!
            let orphan = media.blobs.root.appendingPathComponent(UUID().uuidString.lowercased()); try LocalMediaBlobStore.directory(orphan)
            try Data("plaintext residue".utf8).write(to: media.blobs.work.appendingPathComponent("residue"))
        } catch { try await first.asyncShutdown(); throw error }
        try await first.asyncShutdown()
        let second = try await fixture.app()
        do {
            var login = LoginRequest(); login.operationID = UUID().uuidString; login.deviceID = account.deviceID
            login.accountName = "restart_media"; login.password = "Fictional-Test-Password-123"
            let fresh = try decode(AuthResponse.self, await send(second, .POST, "/v1/auth/login", login))
            let replay = try decode(MediaAssetStatus.self, await send(second, .POST, "/v1/media/assets/create", input, token: fresh.accessToken))
            #expect(replay.assetID == created.assetID); #expect(replay.uploads[0].completedParts == [0])
            let media = second.storage[MediaServiceKey.self]!
            #expect(try FileManager.default.contentsOfDirectory(atPath: media.blobs.work.path).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: media.blobs.root.path).count == 1)
            var complete = MediaAssetMutation(); complete.operationID = UUID().uuidString; complete.assetID = created.assetID
            #expect(try await send(second, .POST, "/v1/media/assets/complete", complete, token: fresh.accessToken).status == .ok)
            try await media.processNext(second.db)
            let record = try #require(try await MediaAssetRecord.find(UUID(uuidString: created.assetID)!, on: second.db)); #expect(record.state == "ready")
            let repeated = try decode(MediaAssetStatus.self, await send(second, .POST, "/v1/media/assets/complete", complete, token: fresh.accessToken)); #expect(repeated.state == "ready")
        } catch { try await second.asyncShutdown(); throw error }
        try await second.asyncShutdown()
    }
}
