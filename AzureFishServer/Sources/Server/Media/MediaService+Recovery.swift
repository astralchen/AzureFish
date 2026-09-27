import Fluent
import Foundation
import Vapor

extension MediaService {
    /// 启动时尚未接收流量，安全清除未提交密文并重排中断任务。
    func recover(_ db: any Database) async throws {
        let assets = try await MediaAssetRecord.query(on: db).all()
        for asset in assets where asset.state == "processing" {
            asset.state = "queued"; try await asset.update(on: db)
            try await enqueue(asset, kind: "process", due: accounts.now, db: db)
        }
        var keep: [String: Set<String>] = [:]
        for resource in try await MediaResourceRecord.query(on: db).all() {
            let id = try resource.requireID()
            var files = Set<String>()
            for part in try await MediaPartRecord.query(on: db).filter(\.$resourceID == id).all() {
                let chunk: MediaChunk = try im.decrypt(part.payload, context: "media-part:" + part.requireID().uuidString)
                files.insert(chunk.filename)
            }
            if let manifest = try resourceState(resource).manifest { files.insert(manifest) }
            keep[id.uuidString.lowercased()] = files
        }
        let retained = keep
        try await blobs.io {
            for directory in try FileManager.default.contentsOfDirectory(at: self.blobs.root, includingPropertiesForKeys: nil) {
                guard UUID(uuidString: directory.lastPathComponent) != nil else { throw APIError(.internalServerError, "MEDIA_STORAGE_UNAVAILABLE") }
                try LocalMediaBlobStore.checkDirectory(directory)
                guard let files = retained[directory.lastPathComponent] else { try FileManager.default.removeItem(at: directory); continue }
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where !files.contains(file.lastPathComponent) {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
        try await expire(db)
        try await collect(db)
    }
    func expire(_ db: any Database) async throws {
        try await accounts.gate.run {
            try await db.transaction { db in
                for asset in try await MediaAssetRecord.query(on: db).filter(\.$expiresAt > 0).filter(\.$expiresAt <= self.accounts.now).filter(\.$reservedBytes > 0).all() {
                    guard try await MediaReferenceRecord.query(on: db).filter(\.$assetID == asset.requireID()).count() == 0 else { continue }
                    if !["expired", "cancelled", "deleted"].contains(asset.state) {
                        asset.state = "expired"; asset.generation += 1; try await asset.update(on: db)
                    }
                    try await self.enqueue(asset, kind: "gc", due: self.accounts.now, db: db)
                }
            }
        }
    }
    func collect(_ db: any Database) async throws {
        let candidates: [(UUID, Int64, [UUID])] = try await accounts.gate.run {
            var values: [(UUID, Int64, [UUID])] = []
            for job in try await MediaJobRecord.query(on: db).filter(\.$kind == "gc").filter(\.$state == "queued").filter(\.$dueAt <= self.accounts.now).all() {
                guard let asset = try await MediaAssetRecord.find(job.assetID, on: db), !["deleted"].contains(asset.state),
                      asset.expiresAt > 0, asset.expiresAt <= self.accounts.now,
                      try await MediaReferenceRecord.query(on: db).filter(\.$assetID == job.assetID).count() == 0 else { continue }
                // 先封闭新访问，再等待已有访问在下个分块边界结束。
                if !["expired", "cancelled"].contains(asset.state) { asset.state = "expired"; asset.generation += 1; try await asset.update(on: db) }
                guard await !self.leases.active(job.assetID) else { continue }
                let ids = try await MediaResourceRecord.query(on: db).filter(\.$assetID == job.assetID).all().map { try $0.requireID() }
                values.append((job.assetID, asset.generation, ids))
            }
            return values
        }
        for (id, generation, resources) in candidates {
            for resource in resources { try await blobs.remove(resource) }
            try await accounts.gate.run {
                try await db.transaction { db in
                    guard let asset = try await MediaAssetRecord.find(id, on: db), asset.generation == generation else { return }
                    for resource in try await MediaResourceRecord.query(on: db).filter(\.$assetID == id).all() {
                        try await MediaPartRecord.query(on: db).filter(\.$resourceID == resource.requireID()).delete()
                        resource.wrappedKey = nil; resource.uploadID = nil
                        try await self.save(resource, MediaResourceState(role: "deleted", filename: "", mime: "", bytes: 0, sha256: ""), db: db)
                    }
                    var state = try self.assetState(asset); state.metadata = nil
                    asset.state = "deleted"; asset.reservedBytes = 0
                    try await self.save(asset, state, db: db)
                    try await MediaJobRecord.query(on: db).filter(\.$assetID == id).set(\.$state, to: "done").update()
                }
            }
        }
    }
}
