import Crypto
import Fluent
import Foundation
import MediaWorkerSupport
import SwiftProtobuf
import Vapor

private struct ProcessingInput: Sendable {
    let asset: UUID
    let generation: Int64
    let kind: String
    let resources: [(MediaResourceTicket, [MediaChunk])]
}
extension MediaService {
    func current(_ id: UUID, generation: Int64, db: any Database) async throws {
        try Task.checkCancellation()
        try await accounts.gate.run {
            guard let row = try await MediaAssetRecord.find(id, on: db), row.generation == generation,
                  self.effectiveState(row) == "processing" else { throw APIError(.conflict, "MEDIA_NOT_AVAILABLE") }
        }
    }
    func processNext(_ db: any Database) async throws {
        let input: ProcessingInput? = try await accounts.gate.run {
            try await db.transaction { db in
                guard let job = try await MediaJobRecord.query(on: db).filter(\.$kind == "process").filter(\.$state == "queued").filter(\.$dueAt <= self.accounts.now).sort(\.$dueAt).first() else { return nil }
                guard let asset = try await MediaAssetRecord.find(job.assetID, on: db), self.effectiveState(asset) == "queued", asset.generation == job.generation else {
                    job.state = "done"; try await job.update(on: db); return nil
                }
                let kind = try self.assetState(asset).kind
                let rows = try await MediaResourceRecord.query(on: db).filter(\.$assetID == job.assetID).all()
                var resources: [(MediaResourceTicket, [MediaChunk])] = []
                for row in rows {
                    let parts = try await MediaPartRecord.query(on: db).filter(\.$resourceID == row.requireID()).sort(\.$index).all()
                    do {
                        resources.append((try self.ticket(row, asset: asset), try parts.map { try self.im.decrypt($0.payload, context: "media-part:" + $0.requireID().uuidString) }))
                    } catch {
                        var state = try self.assetState(asset); state.failure = (error as? APIError)?.code ?? "MEDIA_INTEGRITY_FAILED"
                        asset.state = "failed"; try await self.save(asset, state, db: db)
                        job.state = "done"; try await job.update(on: db); return nil
                    }
                }
                asset.state = "processing"; job.state = "running"
                try await asset.update(on: db); try await job.update(on: db)
                return ProcessingInput(asset: job.assetID, generation: job.generation, kind: kind, resources: resources)
            }
        }
        guard let input, let owner = input.resources.first?.0.owner else { return }
        let lease = try await leases.acquire(user: owner, asset: input.asset, transfer: false, limits: limits)
        let directory = blobs.work.appendingPathComponent(UUID().uuidString.lowercased())
        var derivedID: UUID?
        do {
            var originals: [(MediaResourceTicket, [MediaChunk])] = []
            for (source, chunks) in input.resources {
                try await current(input.asset, generation: input.generation, db: db)
                var source = source; source.state.manifest = try await blobs.finish(chunks, ticket: source)
                originals.append((source, chunks))
            }
            var result = WorkerResult(); result.mime = "application/octet-stream"
            if input.kind != "file" {
                guard FileManager.default.isExecutableFile(atPath: worker) else { throw APIError(.serviceUnavailable, "PROCESSOR_UNAVAILABLE") }
                try await blobs.io { try LocalMediaBlobStore.directory(directory) }
                var paths: [String: String] = [:]
                for (source, chunks) in originals {
                    let ext = URL(fileURLWithPath: source.state.filename).pathExtension.filter { $0.isASCII && $0.isLetter }.prefix(10)
                    let url = directory.appendingPathComponent(source.state.role + "." + ext)
                    try await blobs.io { try LocalMediaBlobStore.atomicWrite(Data(), to: url) }
                    for chunk in chunks {
                        try await current(input.asset, generation: input.generation, db: db)
                        let bytes = try await blobs.read(chunk, ticket: source)
                        try await blobs.io {
                            let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
                            try file.seekToEnd(); try file.write(contentsOf: bytes)
                        }
                    }
                    paths[source.state.role] = url.path
                }
                guard let original = paths["original"] else { throw APIError(.unprocessableEntity, "INVALID_MEDIA") }
                let job = WorkerJob(kind: input.kind, original: original, pairedVideo: paths["paired_video"], outputDirectory: directory.path)
                let jobURL = directory.appendingPathComponent("job.json")
                try await blobs.io { try LocalMediaBlobStore.atomicWrite(JSONEncoder().encode(job), to: jobURL) }
                let process = try await blobs.io { try MediaProcess(executable: self.worker, job: jobURL.path) }
                do {
                    let deadline = Date().addingTimeInterval(limits.processingSeconds)
                    while process.status == nil {
                        try await current(input.asset, generation: input.generation, db: db)
                        guard Date() < deadline else { throw APIError(.unprocessableEntity, "PROCESSING_TIMEOUT") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard process.status == 0 else { throw APIError(.unprocessableEntity, "PROCESSOR_FAILED") }
                } catch {
                    process.kill()
                    try? await blobs.io { process.wait() }
                    throw error
                }
                result = try await blobs.io { try JSONDecoder().decode(WorkerResult.self, from: LocalMediaBlobStore.readRegular(directory.appendingPathComponent("result.json"), max: 65536)) }
                guard result.failure.isEmpty else { throw APIError(.unprocessableEntity, "INVALID_MEDIA") }
                guard result.width >= 0, result.height >= 0, result.durationMS >= 0,
                      result.waveform.count <= 60, result.waveform.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw APIError(.unprocessableEntity, "INVALID_MEDIA") }
            }
            for index in originals.indices {
                let mime = originals[index].0.state.role == "paired_video" ? result.pairedMime : result.mime
                if input.kind != "file", originals[index].0.state.mime != mime { throw APIError(.unprocessableEntity, "MEDIA_TYPE_MISMATCH") }
                originals[index].0.state.mime = mime
            }
            var derived: (MediaResourceTicket, [MediaChunk])?
            if let preview = result.preview {
                guard preview == "preview.jpg" else { throw APIError(.unprocessableEntity, "INVALID_MEDIA") }
                let bytes = try await blobs.io { try LocalMediaBlobStore.readRegular(directory.appendingPathComponent(preview), max: Int(MediaLimits.previewBudget) - 131072) }
                guard !bytes.isEmpty, let first = originals.first?.0 else { throw APIError(.unprocessableEntity, "INVALID_MEDIA") }
                var ticket = MediaResourceTicket(id: UUID(), asset: input.asset, owner: first.owner, generation: input.generation,
                    key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
                    state: MediaResourceState(role: input.kind == "video" ? "cover" : "thumbnail", filename: "preview.jpg", mime: "image/jpeg", bytes: Int64(bytes.count), sha256: LocalMediaBlobStore.hash(bytes)))
                derivedID = ticket.id
                var chunks: [MediaChunk] = []
                for offset in stride(from: 0, to: bytes.count, by: MediaLimits.chunk) {
                    chunks.append(try await blobs.put(Data(bytes[offset..<min(bytes.count, offset + MediaLimits.chunk)]), ticket: ticket, index: chunks.count))
                }
                ticket.state.manifest = try await blobs.finish(chunks, ticket: ticket); derived = (ticket, chunks)
            }
            var metadata = MediaAsset(); metadata.assetID = input.asset.uuidString.lowercased(); metadata.kind = input.kind
            metadata.pixelWidth = Int32(result.width); metadata.pixelHeight = Int32(result.height); metadata.durationMs = result.durationMS
            metadata.animated = result.animated; metadata.waveform = result.waveform; metadata.metadataVersion = 1
            let finished = originals + (derived.map { [$0] } ?? [])
            for (ticket, _) in finished.sorted(by: { $0.0.state.role < $1.0.state.role }) {
                var value = MediaResource(); value.resourceID = ticket.id.uuidString.lowercased(); value.role = ticket.state.role
                value.filename = ticket.state.filename; value.mimeType = ticket.state.mime; value.byteCount = ticket.state.bytes; value.sha256 = ticket.state.sha256
                metadata.resources.append(value)
            }
            let encoded = try metadata.serializedData()
            try await accounts.gate.run {
                try await db.transaction { db in
                    guard let asset = try await MediaAssetRecord.find(input.asset, on: db), asset.generation == input.generation, self.effectiveState(asset) == "processing" else { throw APIError(.conflict, "MEDIA_NOT_AVAILABLE") }
                    for (ticket, chunks) in finished {
                        let existing = try await MediaResourceRecord.find(ticket.id, on: db)
                        let row = existing ?? MediaResourceRecord()
                        if existing == nil {
                            row.id = ticket.id; row.assetID = ticket.asset; row.wrappedKey = try self.crypto.wrapMediaKey(ticket.key, resource: ticket.id)
                        }
                        try await self.save(row, ticket.state, db: db)
                        if existing == nil {
                            for chunk in chunks {
                                let part = MediaPartRecord(); part.id = UUID(); part.resourceID = ticket.id; part.index = chunk.index
                                part.payload = try self.im.encrypt(chunk, context: "media-part:" + part.requireID().uuidString); try await part.create(on: db)
                            }
                        }
                    }
                    var state = try self.assetState(asset); state.metadata = encoded
                    asset.state = "ready"; asset.expiresAt = self.accounts.now + MediaLimits.lifetime
                    try await self.save(asset, state, db: db)
                    try await MediaJobRecord.query(on: db).filter(\.$assetID == input.asset).filter(\.$kind == "process").set(\.$state, to: "done").update()
                }
            }
            derivedID = nil
        } catch {
            let code = (error as? APIError)?.code ?? (error is CancellationError ? "PROCESSING_INTERRUPTED" : "PROCESSOR_FAILED")
            try? await accounts.gate.run {
                try await db.transaction { db in
                    guard let asset = try await MediaAssetRecord.find(input.asset, on: db), asset.generation == input.generation, asset.state == "processing" else { return }
                    if error is CancellationError { asset.state = "queued"; try await self.enqueue(asset, kind: "process", due: self.accounts.now, db: db) }
                    else { asset.state = "failed"; var state = try self.assetState(asset); state.failure = code; try await self.save(asset, state, db: db) }
                    try await asset.update(on: db)
                }
            }
        }
        if let derivedID { try? await blobs.remove(derivedID) }
        try? await blobs.io { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
        await leases.release(lease)
    }
}
