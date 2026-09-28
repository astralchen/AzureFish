import Crypto
import Fluent
import Foundation
import SwiftProtobuf
import Vapor

extension MediaService {
    func capabilities(_ req: Request) async throws -> Response {
        try await im.read(req) { _, _ in
            var value = MediaCapabilities(); value.assetKinds = ["image", "video", "audio", "file", "live_photo"]
            value.chunkBytes = Int64(MediaLimits.chunk); value.imageMaxBytes = 25 * 1024 * 1024
            value.videoMaxBytes = 512 * 1024 * 1024; value.fileMaxBytes = value.videoMaxBytes; value.audioMaxBytes = 20 * 1024 * 1024
            value.groupMaxItems = 20; value.groupMaxBytes = 1024 * 1024 * 1024
            value.accountQuotaBytes = self.limits.accountBytes; value.instanceQuotaBytes = self.limits.instanceBytes
            value.accountConcurrency = Int32(self.limits.accountConcurrency); value.instanceConcurrency = Int32(self.limits.instanceConcurrency)
            value.uploadLifetimeMs = MediaLimits.lifetime; value.grantLifetimeMs = 300_000
            value.audioMinDurationMs = 1000; value.audioMaxDurationMs = 120_000; value.imageMaxPixels = 100_000_000
            value.previewMaxDimension = 1280; value.waveformSamples = 60; value.processingTimeoutMs = Int64(self.limits.processingSeconds * 1000)
            value.imageMaxFrames = 10_000; value.videoMaxDimension = 16384; value.audioMaxChannels = 8; value.audioMaxSampleRate = 192000
            value.filenameMaxBytes = 255; value.readyLifetimeMs = MediaLimits.lifetime; value.dereferencedLifetimeMs = MediaLimits.lifetime
            value.collectionIntervalMs = 300_000; value.derivedReservationBytes = MediaLimits.previewBudget
            for (kind, mimes) in [
                ("image", ["image/jpeg", "image/png", "image/heic", "image/heif", "image/gif", "image/webp", "image/tiff"]),
                ("video", ["video/mp4", "video/quicktime"]), ("audio", ["audio/mp4", "audio/x-caf", "audio/wav"]),
                ("file", ["application/octet-stream"]), ("live_photo", ["image/jpeg", "image/heic", "image/heif", "video/quicktime"])
            ] {
                var format = MediaFormat(); format.kind = kind; format.mimeTypes = mimes; value.formats.append(format)
            }
            value.processorAvailable = FileManager.default.isExecutableFile(atPath: self.worker); return value
        }
    }
    func create(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(MediaCreateRequest.self, from: req)
        guard ["image", "video", "audio", "file", "live_photo"].contains(input.kind) else { throw APIError(.badRequest, "UNSUPPORTED_MEDIA_KIND", field: "kind") }
        let expected = input.kind == "live_photo" ? Set(["original", "paired_video"]) : Set(["original"])
        guard Set(input.resources.map(\.role)) == expected, input.resources.count == expected.count else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "resources") }
        var reserved: Int64 = input.kind == "file" ? 0 : MediaLimits.previewBudget
        for resource in input.resources {
            guard resource.byteCount > 0, resource.byteCount <= limits.maximum(kind: input.kind, role: resource.role),
                  Self.validDigest(resource.sha256), !resource.filename.isEmpty, resource.filename.utf8.count <= 255,
                  !resource.filename.contains("/"), !resource.filename.contains("\\"), ![".", ".."].contains(resource.filename),
                  !resource.filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  resource.mimeType.utf8.count <= 128, resource.mimeType.contains("/"),
                  resource.mimeType.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "resources") }
            reserved += resource.byteCount + ((resource.byteCount + Int64(MediaLimits.chunk) - 1) / Int64(MediaLimits.chunk)) * 28 + 128 * 1024
        }
        let reservation = reserved
        let free = try await blobs.availableBytes()
        return try await mutate(req, operation: input.operationID, bytes: bytes, name: "create") { session, db in
            let (conversation, state) = try await self.im.load(input.conversationID, user: session.userID, db: db, active: true)
            try await self.im.requireSending(user: session.userID, state: state, db: db)
            let all = try await MediaAssetRecord.query(on: db).filter(\.$reservedBytes > 0).all()
            let total = all.reduce(Int64(0)) { $0 + $1.reservedBytes }
            let owned = all.filter { $0.ownerID == session.userID }.reduce(Int64(0)) { $0 + $1.reservedBytes }
            guard total + reservation <= self.limits.instanceBytes, owned + reservation <= self.limits.accountBytes else { throw APIError(.conflict, "MEDIA_QUOTA_EXCEEDED") }
            guard free > total + reservation * 2 + 64 * 1024 * 1024 else { throw APIError(.insufficientStorage, "MEDIA_STORAGE_UNAVAILABLE") }
            let asset = MediaAssetRecord(); asset.id = UUID(); asset.ownerID = session.userID; asset.conversationID = try conversation.requireID()
            asset.state = "uploading"; asset.expiresAt = self.accounts.now + MediaLimits.lifetime; asset.reservedBytes = reservation; asset.generation = 1
            try await self.save(asset, MediaAssetState(kind: input.kind), db: db)
            for source in input.resources {
                let row = MediaResourceRecord(); row.id = UUID(); row.assetID = try asset.requireID(); row.uploadID = UUID()
                let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                row.wrappedKey = try self.crypto.wrapMediaKey(key, resource: row.requireID())
                try await self.save(row, MediaResourceState(role: source.role, filename: source.filename, mime: source.mimeType.lowercased(), bytes: source.byteCount, sha256: source.sha256), db: db)
            }
            return asset
        }
    }
    func status(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(MediaAssetRequest.self, from: req)
        let id = try Validation.uuid(input.assetID, field: "asset_id")
        return try await im.read(req) { session, db in try await self.statusValue(self.owned(id, user: session.userID, db: db), db: db) }
    }
    func complete(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(MediaAssetMutation.self, from: req)
        let id = try Validation.uuid(input.assetID, field: "asset_id")
        return try await mutate(req, operation: input.operationID, bytes: bytes, name: "complete") { session, db in
            let asset = try await self.owned(id, user: session.userID, db: db)
            _ = try await self.im.load(asset.conversationID.uuidString, user: session.userID, db: db, active: true)
            guard ["uploading", "queued", "processing", "ready"].contains(self.effectiveState(asset)) else { throw APIError(.conflict, "MEDIA_NOT_AVAILABLE") }
            if asset.state == "uploading" {
                let resources = try await MediaResourceRecord.query(on: db).filter(\.$assetID == id).all()
                for resource in resources {
                    let expected = try (self.resourceState(resource).bytes + Int64(MediaLimits.chunk) - 1) / Int64(MediaLimits.chunk)
                    guard try await MediaPartRecord.query(on: db).filter(\.$resourceID == resource.requireID()).count() == expected else { throw APIError(.conflict, "UPLOAD_INCOMPLETE") }
                }
                asset.state = "queued"; try await asset.update(on: db)
                try await self.enqueue(asset, kind: "process", due: self.accounts.now, db: db)
            }
            return asset
        }
    }
    func cancel(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(MediaAssetMutation.self, from: req)
        let id = try Validation.uuid(input.assetID, field: "asset_id")
        return try await mutate(req, operation: input.operationID, bytes: bytes, name: "cancel") { session, db in
            let asset = try await self.owned(id, user: session.userID, db: db)
            guard try await MediaReferenceRecord.query(on: db).filter(\.$assetID == id).count() == 0 else { throw APIError(.conflict, "MEDIA_IN_USE") }
            if !["cancelled", "deleted", "expired"].contains(asset.state) {
                asset.state = "cancelled"; asset.generation += 1; asset.expiresAt = self.accounts.now
                try await asset.update(on: db); try await self.enqueue(asset, kind: "gc", due: self.accounts.now, db: db)
            }
            return asset
        }
    }
    func upload(_ req: Request) async throws -> Response {
        let uploadID = try Validation.uuid(req.parameters.get("upload") ?? "", field: "upload_id")
        guard let index = Int(req.parameters.get("index") ?? ""), index >= 0, index < 128,
              req.headers.contentType == HTTPMediaType(type: "application", subType: "octet-stream"), let digest = req.headers.first(name: "X-Content-SHA256"), Self.validDigest(digest) else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "part") }
        let (ticket, lease, prior): (MediaResourceTicket, UUID, MediaChunk?) = try await accounts.gate.run {
            let session = try await self.accounts.authenticate(req, db: req.db)
            guard let resource = try await MediaResourceRecord.query(on: req.db).filter(\.$uploadID == uploadID).first() else { throw APIError(.notFound, "MEDIA_NOT_FOUND") }
            let asset = try await self.owned(resource.assetID, user: session.userID, db: req.db)
            _ = try await self.im.load(asset.conversationID.uuidString, user: session.userID, db: req.db, active: true)
            guard ["uploading", "queued", "processing", "ready"].contains(self.effectiveState(asset)) else { throw APIError(.conflict, "MEDIA_NOT_AVAILABLE") }
            let ticket = try self.ticket(resource, asset: asset)
            guard Int64(index) * Int64(MediaLimits.chunk) < ticket.state.bytes else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "index") }
            let previous = try await MediaPartRecord.query(on: req.db).filter(\.$resourceID == ticket.id).filter(\.$index == index).first()
            let chunk: MediaChunk? = try previous.map { try self.im.decrypt($0.payload, context: "media-part:" + $0.requireID().uuidString) }
            if let chunk, chunk.sha256 != digest { throw APIError(.conflict, "PART_CONFLICT") }
            guard chunk != nil || asset.state == "uploading" else { throw APIError(.conflict, "MEDIA_NOT_AVAILABLE") }
            let lease = try await self.leases.acquire(user: session.userID, asset: ticket.asset, part: uploadID.uuidString + ":" + String(index), limits: self.limits)
            return (ticket, lease, chunk)
        }
        var uncommitted: MediaChunk?
        do {
            let expected = min(MediaLimits.chunk, Int(ticket.state.bytes) - index * MediaLimits.chunk)
            if let count = req.headers.first(name: .contentLength), Int(count) != expected { throw APIError(.badRequest, "PART_SIZE_MISMATCH") }
            var bytes = Data(); bytes.reserveCapacity(expected)
            for try await buffer in req.body {
                guard buffer.readableBytes <= expected - bytes.count else { throw APIError(.payloadTooLarge, "PAYLOAD_TOO_LARGE") }
                bytes.append(contentsOf: buffer.readableBytesView)
            }
            guard bytes.count == expected else { throw APIError(.badRequest, "PART_SIZE_MISMATCH") }
            guard LocalMediaBlobStore.hash(bytes) == digest else { throw APIError(.unprocessableEntity, "CONTENT_DIGEST_MISMATCH") }
            let chunk: MediaChunk
            if let prior { chunk = prior; _ = try await blobs.read(prior, ticket: ticket) }
            else { chunk = try await blobs.put(bytes, ticket: ticket, index: index); uncommitted = chunk }
            try await accounts.gate.run {
                try await req.db.transaction { db in
                    let session = try await self.accounts.authenticate(req, db: db)
                    let asset = try await self.owned(ticket.asset, user: session.userID, db: db)
                    _ = try await self.im.load(asset.conversationID.uuidString, user: session.userID, db: db, active: true)
                    guard asset.generation == ticket.generation, ["uploading", "queued", "processing", "ready"].contains(self.effectiveState(asset)), prior != nil || asset.state == "uploading" else { throw APIError(.conflict, "MEDIA_NOT_AVAILABLE") }
                    if prior == nil {
                        let part = MediaPartRecord(); part.id = UUID(); part.resourceID = ticket.id; part.index = index
                        part.payload = try self.im.encrypt(chunk, context: "media-part:" + part.requireID().uuidString); try await part.create(on: db)
                    }
                }
            }
            uncommitted = nil
            await leases.release(lease)
            var result = MediaPartResponse(); result.index = Int32(index); result.byteCount = Int64(chunk.bytes); result.sha256 = chunk.sha256
            return try protobufResponse(result)
        } catch {
            if let uncommitted { try? await blobs.discard(uncommitted, ticket: ticket) }
            await leases.release(lease); throw error
        }
    }
}
