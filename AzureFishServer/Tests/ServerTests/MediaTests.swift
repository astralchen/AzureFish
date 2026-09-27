@testable import Server
import Crypto
import Fluent
import Foundation
import SwiftProtobuf
import Testing
import VaporTesting

struct MediaHTTP: Sendable {
    let base: URL
    func raw(_ method: String, _ path: String, bytes: Data? = nil, token: String, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: base.appendingPathComponent(path)); req.httpMethod = method; req.httpBody = bytes
        req.timeoutInterval = 150; req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: req)
        return (data, try #require(response as? HTTPURLResponse))
    }
    func call<I: Message, O: Message>(_ path: String, _ input: I, _ type: O.Type, user: AuthResponse) async throws -> O {
        let (data, response) = try await raw("POST", path, bytes: input.serializedData(), token: user.accessToken, headers: ["Content-Type": "application/protobuf"])
        guard response.statusCode == 200 else { let error = try ApiError(serializedBytes: data); Issue.record("\(path): \(error.code)"); throw APIError(.init(statusCode: response.statusCode), error.code) }
        return try O(serializedBytes: data)
    }
    func status(_ id: String, user: AuthResponse) async throws -> MediaAssetStatus {
        var input = MediaAssetRequest(); input.assetID = id
        return try await call("v1/media/assets/status", input, MediaAssetStatus.self, user: user)
    }
    func finish(_ id: String, user: AuthResponse) async throws -> MediaAssetStatus {
        var input = MediaAssetMutation(); input.operationID = UUID().uuidString; input.assetID = id
        _ = try await call("v1/media/assets/complete", input, MediaAssetStatus.self, user: user)
        for _ in 0..<600 {
            let state = try await status(id, user: user)
            if ["ready", "failed", "deleted", "expired"].contains(state.state) { return state }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw APIError(.requestTimeout, "TEST_PROCESS_TIMEOUT")
    }
    func create(_ kind: String, sources: [(String, String, String, Data)], conversation: IMConversation, user: AuthResponse) async throws -> MediaAssetStatus {
        var input = MediaCreateRequest(); input.operationID = UUID().uuidString; input.conversationID = conversation.conversationID; input.kind = kind
        for (role, name, mime, bytes) in sources {
            var value = MediaResourceInput(); value.role = role; value.filename = name; value.mimeType = mime
            value.byteCount = Int64(bytes.count); value.sha256 = LocalMediaBlobStore.hash(bytes); input.resources.append(value)
        }
        let created = try await call("v1/media/assets/create", input, MediaAssetStatus.self, user: user)
        #expect(try await call("v1/media/assets/create", input, MediaAssetStatus.self, user: user).assetID == created.assetID)
        return created
    }
    func upload(_ progress: MediaUploadProgress, bytes: Data, index: Int, user: AuthResponse, expected: Int = 200) async throws {
        let (data, response) = try await raw("PUT", "v1/media/uploads/\(progress.uploadID)/parts/\(index)", bytes: bytes, token: user.accessToken,
            headers: ["Content-Type": "application/octet-stream", "X-Content-SHA256": LocalMediaBlobStore.hash(bytes)])
        #expect(response.statusCode == expected)
        if response.statusCode != expected { Issue.record("Media upload failed: \(String(describing: try? ApiError(serializedBytes: data).code))") }
    }
    func grant(_ resource: MediaResource, user: AuthResponse, message: String = "") async throws -> MediaDownloadGrant {
        var input = MediaAuthorizeRequest(); input.resourceID = resource.resourceID; input.purpose = message.isEmpty ? "draft_preview" : "message_view"; input.messageUuid = message
        return try await call("v1/media/resources/authorize", input, MediaDownloadGrant.self, user: user)
    }
}
func withMediaHTTP(_ body: (Application, Fixture, MediaHTTP) async throws -> Void) async throws {
    try await withServer { app, fixture in
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        let port = try #require(app.http.server.shared.localAddress?.port)
        let media = try #require(app.storage[MediaServiceKey.self]); await media.runtime.start(media, app: app)
        do { try await body(app, fixture, MediaHTTP(base: URL(string: "http://127.0.0.1:\(port)")!)) }
        catch { await app.server.shutdown(); throw error }
        await app.server.shutdown()
    }
}
func mediaFixture(_ name: String) throws -> Data { try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name)) }

@Suite("媒体后台", .serialized)
struct MediaTests {
    @Test func nativeFormatsOverHTTP() async throws {
        try await withMediaHTTP { app, _, http in
            let a = try await auth(app, name: "media_a"), b = try await auth(app, name: "media_b")
            let chat = try await direct(app, a, b)
            let cases: [(String, [(String, String, String)])] = [
                ("image", [("original", "preview-image-08.png", "image/png")]),
                ("image", [("original", "preview-image-01.gif", "image/gif")]),
                ("video", [("original", "live-photo.mov", "video/quicktime")]),
                ("audio", [("original", "default-message.caf", "audio/x-caf")]),
                ("live_photo", [("original", "live-photo.jpg", "image/jpeg"), ("paired_video", "live-photo.mov", "video/quicktime")]),
            ]
            var grouped: [String] = []
            for (kind, files) in cases {
                let sources = try files.map { ($0.0, $0.1, $0.2, try mediaFixture($0.1)) }
                let created = try await http.create(kind, sources: sources, conversation: chat, user: a)
                // resource_id 对应创建请求顺序，状态按资源身份排序；查询加密元数据确认角色。
                for progress in created.uploads {
                    let row = try #require(try await MediaResourceRecord.find(UUID(uuidString: progress.resourceID)!, on: app.db))
                    let role = try app.storage[MediaServiceKey.self]!.resourceState(row).role
                    let bytes = try #require(sources.first { $0.0 == role }).3
                    for index in (0..<Int(progress.partCount)).reversed() {
                        let start = index * MediaLimits.chunk
                        try await http.upload(progress, bytes: Data(bytes[start..<min(bytes.count, start + MediaLimits.chunk)]), index: index, user: a)
                    }
                }
                let ready = try await http.finish(created.assetID, user: a)
                #expect(ready.state == "ready", "\(kind): \(ready.failureCode)")
                guard ready.state == "ready" else { continue }
                if kind == "audio" { #expect(ready.asset.waveform.count == 60) }
                if files[0].1.hasSuffix("gif") { #expect(ready.asset.animated) }
                var sendInput = outgoing(chat, a, text: ""); sendInput.contentType = kind == "audio" ? "audio" : "media_group"; sendInput.assetIds = [ready.assetID]
                let message = try await http.call("v1/im/messages/send", sendInput, IMMessage.self, user: a)
                #expect(message.assets == [ready.asset])
                for resource in ready.asset.resources {
                    let grant = try await http.grant(resource, user: b, message: message.messageUuid)
                    let (bytes, response) = try await http.raw("GET", "v1/media/resources/\(resource.resourceID)/content", token: b.accessToken, headers: ["X-Media-Grant": grant.token])
                    #expect(response.statusCode == 200); #expect(LocalMediaBlobStore.hash(bytes) == resource.sha256)
                }
                let history = try await http.call("v1/im/history", historyInput(chat), IMHistoryResponse.self, user: b)
                #expect(history.messages.contains { $0.messageUuid == message.messageUuid && $0.assets == message.assets })
                if kind != "audio" { grouped.append(ready.assetID) }
            }
            var input = outgoing(chat, a, text: ""); input.contentType = "media_group"; input.assetIds = grouped.reversed()
            let groupMessage = try await http.call("v1/im/messages/send", input, IMMessage.self, user: a)
            #expect(groupMessage.assets.map(\.assetID) == Array(grouped.reversed()))
        }
    }
    @Test func fileResumeRangeRevokeAndCollection() async throws {
        try await withMediaHTTP { app, fixture, http in
            let a = try await auth(app, name: "file_a"), b = try await auth(app, name: "file_b"), c = try await auth(app, name: "file_c")
            let chat = try await direct(app, a, b)
            let bytes = Data(repeating: 42, count: MediaLimits.chunk) + Data("tail".utf8)
            let created = try await http.create("file", sources: [("original", "虚构.bin", "application/octet-stream", bytes)], conversation: chat, user: a)
            let progress = try #require(created.uploads.first)
            try await http.upload(progress, bytes: Data(bytes.suffix(4)), index: 1, user: a)
            #expect(try await http.status(created.assetID, user: a).uploads[0].completedParts == [1])
            try await http.upload(progress, bytes: Data(bytes.prefix(MediaLimits.chunk)), index: 0, user: a)
            try await http.upload(progress, bytes: Data(bytes.suffix(4)), index: 1, user: a)
            try await http.upload(progress, bytes: Data("xxxx".utf8), index: 1, user: a, expected: 409)
            let ready = try await http.finish(created.assetID, user: a); #expect(ready.state == "ready")
            let resource = try #require(ready.asset.resources.first)
            let draft = try await http.grant(resource, user: a)
            let path = "v1/media/resources/\(resource.resourceID)/content"
            for _ in 0..<6 {
                let (body, head) = try await http.raw("HEAD", path, token: a.accessToken, headers: ["X-Media-Grant": draft.token, "Range": "bytes=0-1"])
                #expect(head.statusCode == 200); #expect(body.isEmpty)
                #expect(head.value(forHTTPHeaderField: "Content-Length") == String(bytes.count))
            }
            #expect(await !app.storage[MediaServiceKey.self]!.leases.active(UUID(uuidString: created.assetID)!))
            for range in ["bytes=4194302-4194307", "bytes=-4", "bytes=4194304-"] {
                let (part, response) = try await http.raw("GET", path, token: a.accessToken, headers: ["X-Media-Grant": draft.token, "Range": range])
                #expect(response.statusCode == 206); #expect(part.suffix(4) == bytes.suffix(4))
            }
            let (_, badRange) = try await http.raw("GET", path, token: a.accessToken, headers: ["X-Media-Grant": draft.token, "Range": "bytes=999999999-"])
            #expect(badRange.statusCode == 416); #expect(badRange.value(forHTTPHeaderField: "Content-Range") == "bytes */4194308")
            let (full, fallback) = try await http.raw("GET", path, token: a.accessToken, headers: ["X-Media-Grant": draft.token, "Range": "bytes=0-1", "If-Range": "\"wrong\""])
            #expect(fallback.statusCode == 200); #expect(full == bytes)
            var input = outgoing(chat, a, text: ""); input.contentType = "file"; input.assetIds = [created.assetID]
            let first = try await http.call("v1/im/messages/send", input, IMMessage.self, user: a)
            var another = outgoing(chat, a, text: ""); another.contentType = "file"; another.assetIds = input.assetIds
            let second = try await http.call("v1/im/messages/send", another, IMMessage.self, user: a)
            let grant = try await http.grant(resource, user: b, message: first.messageUuid)
            let secondGrant = try await http.grant(resource, user: b, message: second.messageUuid)
            let (_, cross) = try await http.raw("GET", path, token: c.accessToken, headers: ["X-Media-Grant": grant.token]); #expect(cross.statusCode == 403)
            var revoke = IMRevokeRequest(); revoke.operationID = UUID().uuidString; revoke.conversationID = chat.conversationID; revoke.messageUuid = first.messageUuid
            _ = try await http.call("v1/im/messages/revoke", revoke, IMMessage.self, user: a)
            #expect(try await http.call("v1/im/messages/send", input, IMMessage.self, user: a).assets.isEmpty)
            let (_, denied) = try await http.raw("GET", path, token: b.accessToken, headers: ["X-Media-Grant": grant.token]); #expect(denied.statusCode == 404)
            let (_, draftDenied) = try await http.raw("GET", path, token: a.accessToken, headers: ["X-Media-Grant": draft.token]); #expect(draftDenied.statusCode == 404)
            let (_, kept) = try await http.raw("GET", path, token: b.accessToken, headers: ["X-Media-Grant": secondGrant.token]); #expect(kept.statusCode == 200)
            revoke.operationID = UUID().uuidString; revoke.messageUuid = second.messageUuid
            _ = try await http.call("v1/im/messages/revoke", revoke, IMMessage.self, user: a)
            fixture.clock.advance(86401)
            let media = app.storage[MediaServiceKey.self]!
            try await media.expire(app.db); try await media.collect(app.db)
            let record = try #require(try await MediaAssetRecord.find(UUID(uuidString: created.assetID)!, on: app.db))
            #expect(record.state == "deleted"); #expect(record.reservedBytes == 0)
            #expect(try await MediaResourceRecord.find(UUID(uuidString: resource.resourceID)!, on: app.db)?.wrappedKey == nil)
        }
    }
}
