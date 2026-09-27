import Fluent
import Foundation
import SwiftProtobuf
import Vapor

extension MediaService {
    func authorize(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(MediaAuthorizeRequest.self, from: req)
        let resource = try Validation.uuid(input.resourceID, field: "resource_id")
        guard ["draft_preview", "message_view"].contains(input.purpose), input.purpose != "draft_preview" || input.messageUuid.isEmpty else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "purpose") }
        let message = input.purpose == "message_view" ? try Validation.uuid(input.messageUuid, field: "message_uuid") : nil
        return try await im.read(req) { session, db in
            guard let row = try await MediaResourceRecord.find(resource, on: db), let asset = try await MediaAssetRecord.find(row.assetID, on: db) else { throw APIError(.notFound, "MEDIA_NOT_FOUND") }
            let grant = try MediaGrant(user: session.userID, session: session.requireID(), resource: resource, asset: asset.requireID(), purpose: input.purpose, message: message, generation: asset.generation, expires: self.accounts.now + 300_000)
            let ticket = try await self.validate(grant, session: session, db: db)
            var response = MediaDownloadGrant(); response.token = try self.im.encrypt(grant, context: "media-grant-v1")
            response.expiresAtMs = grant.expires; response.resourceID = input.resourceID.lowercased()
            response.etag = self.etag(ticket); response.byteCount = ticket.state.bytes; return response
        }
    }
    func validate(_ grant: MediaGrant, session: SessionRecord, db: any Database) async throws -> MediaResourceTicket {
        guard grant.user == session.userID, grant.session == (try session.requireID()), grant.expires > accounts.now else { throw APIError(.forbidden, "MEDIA_GRANT_EXPIRED") }
        guard let resource = try await MediaResourceRecord.find(grant.resource, on: db), resource.assetID == grant.asset,
              let asset = try await MediaAssetRecord.find(grant.asset, on: db), effectiveState(asset) == "ready", asset.generation == grant.generation else { throw APIError(.notFound, "MEDIA_NOT_FOUND") }
        if grant.purpose == "draft_preview" {
            guard asset.ownerID == session.userID, try !assetState(asset).wasPublished else { throw APIError(.notFound, "MEDIA_NOT_FOUND") }
        } else if grant.purpose == "message_view", let messageID = grant.message {
            let (_, state) = try await im.load(asset.conversationID.uuidString, user: session.userID, db: db)
            let message = try await im.visibleMessage(messageID, conversation: asset.conversationID, state: state, user: session.userID, db: db)
            guard try !im.storedMessage(message).revoked,
                  try await MediaReferenceRecord.query(on: db).filter(\.$assetID == grant.asset).filter(\.$messageID == messageID).first() != nil else { throw APIError(.notFound, "MEDIA_NOT_FOUND") }
        } else { throw APIError(.forbidden, "MEDIA_GRANT_INVALID") }
        return try ticket(resource, asset: asset)
    }
    func etag(_ ticket: MediaResourceTicket) -> String { "\"" + ticket.id.uuidString.lowercased() + "-1\"" }
    func download(_ req: Request) async throws -> Response {
        let id = try Validation.uuid(req.parameters.get("resource") ?? "", field: "resource_id")
        guard let token = req.headers.first(name: "X-Media-Grant"), token.utf8.count <= 4096,
              let grant: MediaGrant = try? im.decrypt(token, context: "media-grant-v1"), grant.resource == id else { throw APIError(.forbidden, "MEDIA_GRANT_INVALID") }
        let (ticket, lease) = try await accounts.gate.run {
            let session = try await self.accounts.authenticate(req, db: req.db)
            let ticket = try await self.validate(grant, session: session, db: req.db)
            let lease = try await self.leases.acquire(user: session.userID, asset: ticket.asset, limits: self.limits)
            return (ticket, lease)
        }
        let lifetime = MediaDownloadLease(leases: leases, id: lease)
        do {
            let tag = etag(ticket)
            let range = try MediaByteRange.parse(req.method == .HEAD ? nil : req.headers.first(name: .range), ifRange: req.headers.first(name: "If-Range"), etag: tag, size: ticket.state.bytes)
            let manifest = try await blobs.manifest(ticket)
            let mediaType = ticket.state.mime
            if let accept = req.headers.first(name: .accept), !accept.split(separator: ",").contains(where: {
                let value = ($0.split(separator: ";").first ?? "").trimmingCharacters(in: .whitespaces)
                return value == "*/*" || value == "application/octet-stream" || value == mediaType || value == mediaType.split(separator: "/")[0] + "/*"
            }) { throw APIError(.notAcceptable, "NOT_ACCEPTABLE") }
            var headers: HTTPHeaders = ["Content-Type": mediaType, "ETag": tag, "Accept-Ranges": "bytes", "Cache-Control": "no-store"]
            let filename = ticket.state.filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "download"
            headers.replaceOrAdd(name: "Content-Disposition", value: "attachment; filename=\"download\"; filename*=UTF-8''" + filename)
            if range.partial { headers.replaceOrAdd(name: "Content-Range", value: "bytes \(range.start)-\(range.end)/\(ticket.state.bytes)") }
            if req.method == .HEAD {
                await leases.release(lease)
                let response = Response(status: .ok, headers: headers)
                // HEAD 没有响应体，仍须报告 GET 表示的长度；Response 初始化会先写入 0。
                response.headers.replaceOrAdd(name: .contentLength, value: String(ticket.state.bytes))
                return response
            }
            let service = self
            let body = Response.Body(managedAsyncStream: { writer in
                defer { withExtendedLifetime(lifetime) {} }
                do {
                    for index in (Int(range.start) / MediaLimits.chunk)...(Int(range.end) / MediaLimits.chunk) {
                        try Task.checkCancellation()
                        // 每个分块重新鉴权；已开始传输的当前块可能完成，之后不再发送。
                        _ = try await service.accounts.gate.run {
                            let session = try await service.accounts.authenticate(req, db: req.db)
                            return try await service.validate(grant, session: session, db: req.db)
                        }
                        let chunk = manifest.chunks[index]
                        let bytes = try await service.blobs.read(chunk, ticket: ticket)
                        let offset = Int64(index * MediaLimits.chunk)
                        let lower = Int(max(0, range.start - offset)), upper = Int(min(Int64(bytes.count), range.end - offset + 1))
                        try await writer.write(.buffer(ByteBuffer(bytes: bytes[lower..<upper])))
                    }
                    await service.leases.release(lease)
                } catch { await service.leases.release(lease); throw error }
            }, count: Int(range.end - range.start + 1))
            return Response(status: range.partial ? .partialContent : .ok, headers: headers, body: body)
        } catch { await leases.release(lease); throw error }
    }
}

struct MediaByteRange: Sendable {
    var start: Int64
    var end: Int64
    var partial: Bool
    static func parse(_ input: String?, ifRange: String?, etag: String, size: Int64) throws -> Self {
        guard size > 0 else { throw APIError(.rangeNotSatisfiable, "RANGE_NOT_SATISFIABLE", contentRange: "bytes */\(size)") }
        guard let input, ifRange == nil || ifRange == etag else { return Self(start: 0, end: size - 1, partial: false) }
        guard input.hasPrefix("bytes="), !input.contains(",") else { throw APIError(.badRequest, "INVALID_RANGE") }
        let values = input.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard values.count == 2 else { throw APIError(.badRequest, "INVALID_RANGE") }
        func number(_ value: Substring) throws -> Int64 {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let result = Int64(value) else { throw APIError(.badRequest, "INVALID_RANGE") }; return result
        }
        let start: Int64, end: Int64
        if values[0].isEmpty {
            let suffix = try number(values[1]); guard suffix > 0 else { throw APIError(.rangeNotSatisfiable, "RANGE_NOT_SATISFIABLE", contentRange: "bytes */\(size)") }
            start = max(0, size - suffix); end = size - 1
        } else {
            start = try number(values[0]); end = values[1].isEmpty ? size - 1 : min(size - 1, try number(values[1]))
        }
        guard start < size, end >= start else { throw APIError(.rangeNotSatisfiable, "RANGE_NOT_SATISFIABLE", contentRange: "bytes */\(size)") }
        return Self(start: start, end: end, partial: true)
    }
}

/// 响应尚未进入流式回调就被断开时，也释放并发名额。
private final class MediaDownloadLease: Sendable {
    let leases: MediaLeases
    let id: UUID
    init(leases: MediaLeases, id: UUID) { self.leases = leases; self.id = id }
    deinit {
        let leases = leases, id = id
        Task { await leases.release(id) }
    }
}
