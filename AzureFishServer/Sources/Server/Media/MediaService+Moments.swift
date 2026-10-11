import Fluent
import Foundation
import SwiftProtobuf
import Vapor

extension MediaService {
    /// 检查聊天与朋友圈两类引用，防止任一业务域单独回收仍在使用的资产。
    static func hasReferences(_ asset: UUID, db: any Database) async throws -> Bool {
        if try await MediaReferenceRecord.query(on: db).filter(\.$assetID == asset).count() > 0 { return true }
        return try await MomentMediaReference.query(on: db).filter(\.$assetID == asset).count() > 0
    }
    /// 验证上传用途的业务访问条件；调用方须先加载并校验资产所有权。
    func requireUploadAccess(_ asset: MediaAssetRecord, user: UUID, db: any Database) async throws {
        if asset.purpose == "chat", let conversation = asset.conversationID {
            _ = try await im.load(conversation.uuidString, user: user, db: db, active: true)
        } else {
            guard asset.ownerID == user, ["moments_post", "moments_cover"].contains(asset.purpose), asset.conversationID == nil else {
                throw APIError(.notFound, "MEDIA_NOT_FOUND")
            }
        }
    }
    /// 按输入顺序绑定已就绪的自有媒体，并取消资产过期；须在发布或封面写事务内调用。
    ///
    /// 用途与媒体类型必须匹配；视频还须具备封面且时长不超过 60 秒。
    func attachMoments(_ ids: [String], target: UUID, purpose: String, kind: String = "image", user: UUID, db: any Database) async throws -> [MediaAsset] {
        var result: [MediaAsset] = []
        for id in ids {
            let asset = try await owned(Validation.uuid(id, field: "asset_ids"), user: user, db: db)
            var state = try assetState(asset)
            guard asset.purpose == purpose, asset.conversationID == nil, effectiveState(asset) == "ready",
                  state.kind == kind, let data = state.metadata else { throw APIError(.conflict, "MEDIA_NOT_READY") }
            let metadata = try MediaAsset(serializedBytes: data)
            if kind == "video" {
                guard purpose == "moments_post", metadata.durationMs > 0, metadata.durationMs <= 60_000,
                      metadata.resources.contains(where: { $0.role == "cover" }) else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "video_asset_id") }
            }
            let ref = MomentMediaReference(); ref.id = UUID(); ref.assetID = try asset.requireID(); ref.targetID = target; ref.purpose = purpose
            try await ref.create(on: db)
            asset.expiresAt = 0; state.wasPublished = true; try await save(asset, state, db: db)
            result.append(metadata)
        }
        return result
    }
    /// 重新验证授权的用途、目标引用和当前可见性，防止旧授权在删除或失权后继续下载。
    func validateMoments(_ grant: MediaGrant, asset: MediaAssetRecord, db: any Database) async throws {
        guard grant.purpose == asset.purpose, let target = grant.momentsTarget,
              try await MomentMediaReference.query(on: db).filter(\.$assetID == grant.asset)
                .filter(\.$targetID == target).filter(\.$purpose == grant.purpose).first() != nil else {
            throw APIError(.notFound, "MEDIA_NOT_FOUND")
        }
        let moments = MomentsService(im: im)
        if grant.purpose == "moments_post" { _ = try await moments.load(target, viewer: grant.user, db: db) }
        else {
            guard target == asset.ownerID, try await moments.canSee(grant.user, target, db: db) else { throw APIError(.notFound, "MEDIA_NOT_FOUND") }
        }
    }
}
