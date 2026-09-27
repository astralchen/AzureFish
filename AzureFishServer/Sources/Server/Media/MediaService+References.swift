import Fluent
import Foundation
import SwiftProtobuf
import Vapor

extension MediaService {
    /// 在发送消息的原事务中绑定全部附件；任一失败不分配消息或部分引用。
    func attach(_ ids: [String], kind: String, conversation: UUID, message: UUID, user: UUID, db: any Database) async throws -> [MediaAsset] {
        let identifiers = try ids.map { try Validation.uuid($0, field: "asset_ids") }
        guard Set(identifiers).count == identifiers.count,
              kind == "media_group" ? (1...20).contains(ids.count) : ids.count == 1 else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "asset_ids") }
        var values: [MediaAsset] = []; var total: Int64 = 0
        for id in identifiers {
            let row = try await owned(id, user: user, db: db)
            var state = try assetState(row)
            guard row.conversationID == conversation, effectiveState(row) == "ready", let metadata = state.metadata else { throw APIError(.conflict, "MEDIA_NOT_READY") }
            let value = try MediaAsset(serializedBytes: metadata)
            guard kind == "media_group" ? ["image", "video", "live_photo"].contains(value.kind) : value.kind == kind else { throw APIError(.badRequest, "MEDIA_KIND_MISMATCH") }
            total += value.resources.filter { ["original", "paired_video"].contains($0.role) }.reduce(0) { $0 + $1.byteCount }
            guard total <= 1024 * 1024 * 1024 else { throw APIError(.payloadTooLarge, "MEDIA_GROUP_TOO_LARGE") }
            let reference = MediaReferenceRecord(); reference.id = UUID(); reference.assetID = id; reference.messageID = message
            try await reference.create(on: db)
            row.expiresAt = 0; state.wasPublished = true; try await save(row, state, db: db)
            values.append(value)
        }
        return values
    }
    /// 撤回只移除该消息引用；最后引用移除后保留延迟回收窗口。
    func detach(message: UUID, db: any Database) async throws {
        let references = try await MediaReferenceRecord.query(on: db).filter(\.$messageID == message).all()
        for reference in references {
            let assetID = reference.assetID
            try await reference.delete(on: db)
            if try await MediaReferenceRecord.query(on: db).filter(\.$assetID == assetID).count() == 0,
               let row = try await MediaAssetRecord.find(assetID, on: db) {
                row.expiresAt = accounts.now + MediaLimits.lifetime
                try await row.update(on: db); try await enqueue(row, kind: "gc", due: row.expiresAt, db: db)
            }
        }
    }
}
