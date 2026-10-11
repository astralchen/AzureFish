import Fluent
import Foundation
import SwiftProtobuf
import Vapor

/// 绑定查看者与作者筛选的分页位置；upper 固定本轮上界，before 指向扫描边界。
private struct MomentsCursor: Codable {
    let viewer: UUID
    let author: UUID?
    let upper: Int64
    let before: Int64
}
extension MomentsService {
    /// 返回当前可见动态的降序页；游标推进以扫描记录为准，空页也可能还有后续页。
    func list(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(MomentsListRequest.self, from: req)
        let author = input.authorID.isEmpty ? nil : try Validation.uuid(input.authorID, field: "author_id")
        let limit = try im.limit(input.limit, max: 50, default: 20)
        return try await im.read(req) { session, db in
            if let author, try await !self.canSee(session.userID, author, db: db) { throw APIError(.notFound, "MOMENT_UNAVAILABLE") }
            let cursor: MomentsCursor
            if input.cursor.isEmpty {
                let upper = try await MomentRecord.query(on: db).sort(\.$sequence, .descending).first()?.sequence ?? 0
                cursor = MomentsCursor(viewer: session.userID, author: author, upper: upper, before: upper + 1)
            } else {
                guard input.cursor.utf8.count <= 2048,
                      let bytes = try? self.im.crypto.open(input.cursor, context: "moments-cursor"),
                      let value = try? JSONDecoder().decode(MomentsCursor.self, from: bytes),
                      value.viewer == session.userID, value.author == author, value.before > 0, value.before <= value.upper + 1 else {
                    throw APIError(.badRequest, "INVALID_CURSOR")
                }
                cursor = value
            }
            // 按受众先筛选作者，避免为每个不相关账号扫描全部历史。
            var owners = [session.userID]
            if let author { owners = [author] }
            else {
                let rows = try await ContactRecord.query(on: db).group(.or) {
                    $0.filter(\.$firstUser == session.userID).filter(\.$secondUser == session.userID)
                }.all()
                for row in rows {
                    let peer = row.firstUser == session.userID ? row.secondUser : row.firstUser
                    if try await self.canSee(session.userID, peer, db: db) { owners.append(peer) }
                }
            }
            let rows = try await MomentRecord.query(on: db).filter(\.$ownerID ~~ owners)
                .filter(\.$sequence <= cursor.upper).filter(\.$sequence < cursor.before)
                .sort(\.$sequence, .descending).limit(limit + 1).all()
            var response = MomentsListResponse()
            var lastScanned: Int64?
            var budgetStopped = false
            for row in rows.prefix(limit) {
                let value = try await self.view(row, viewer: session.userID, db: db)
                if !value.deleted {
                    let bytes = try value.serializedData().count
                    if try response.serializedData().count + bytes > 3 * 1024 * 1024 {
                        guard lastScanned != nil else { throw APIError(.conflict, "MOMENT_INTERACTION_LIMIT") }
                        budgetStopped = true; break
                    }
                    response.posts.append(value)
                }
                // 墓碑也占用扫描位置；否则整页都是已删除记录时游标无法前进。
                lastScanned = row.sequence
            }
            response.hasMore_p = budgetStopped || rows.count > limit
            if response.hasMore_p, let lastScanned {
                response.nextCursor = try self.im.crypto.seal(JSONEncoder().encode(MomentsCursor(
                    viewer: session.userID, author: author, upper: cursor.upper, before: lastScanned)), context: "moments-cursor")
            }
            return response
        }
    }
    /// 校验最多 100 个动态 ID，分别返回当前快照和不可用 ID；不泄露不可用原因。
    func get(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(MomentsGetRequest.self, from: req)
        guard input.postIds.count <= 100 else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "post_ids") }
        let ids = try input.postIds.map { try Validation.uuid($0, field: "post_ids") }
        return try await im.read(req) { session, db in
            var result = MomentsGetResponse()
            for id in Set(ids) {
                if let row = try await MomentRecord.find(id, on: db), try await self.canSee(session.userID, row.ownerID, db: db),
                   try !MomentPost(serializedBytes: self.state(row).envelope).deleted {
                    result.posts.append(try await self.view(row, viewer: session.userID, db: db))
                    guard try result.serializedData().count <= 3 * 1024 * 1024 else { throw APIError(.payloadTooLarge, "PAYLOAD_TOO_LARGE") }
                } else { result.unavailableIds.append(id.uuidString.lowercased()) }
            }
            return result
        }
    }
    /// 为作者查询发布结果，包含删除墓碑，供响应丢失后的发布对账。
    func result(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(MomentIdentityRequest.self, from: req)
        let id = try Validation.uuid(input.postID, field: "post_id")
        return try await im.read(req) { session, db in
            let row = try await self.load(id, viewer: session.userID, db: db, tombstone: true)
            guard row.ownerID == session.userID else { throw APIError(.notFound, "MOMENT_UNAVAILABLE") }
            return try await self.view(row, viewer: session.userID, db: db)
        }
    }
    /// 返回当前账号有权查看的指定相册。
    func album(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(MomentAlbumRequest.self, from: req)
        let owner = try Validation.uuid(input.ownerID, field: "owner_id")
        return try await im.read(req) { session, db in try await self.albumValue(owner, viewer: session.userID, db: db) }
    }
}
