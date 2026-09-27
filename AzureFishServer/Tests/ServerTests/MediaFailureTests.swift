@testable import Server
import Fluent
import Foundation
import SwiftProtobuf
import Testing
import VaporTesting

@Suite("媒体失败与权限", .serialized)
struct MediaFailureTests {
    @Test func invalidMediaMissingPairCancellationAndQuota() async throws {
        try await withMediaHTTP { app, _, http in
            let a = try await auth(app, name: "failure_a"), b = try await auth(app, name: "failure_b")
            let chat = try await direct(app, a, b)
            let bytes = Data("not an image".utf8)
            let created = try await http.create("image", sources: [("original", "fake.png", "image/png", bytes)], conversation: chat, user: a)
            try await http.upload(created.uploads[0], bytes: bytes, index: 0, user: a)
            let failed = try await http.finish(created.assetID, user: a)
            #expect(failed.state == "failed" && failed.failureCode == "INVALID_MEDIA")
            let wrong = try await http.create("image", sources: [("original", "fake.jpg", "image/jpeg", mediaFixture("preview-image-08.png"))], conversation: chat, user: a)
            try await http.upload(wrong.uploads[0], bytes: mediaFixture("preview-image-08.png"), index: 0, user: a)
            #expect(try await http.finish(wrong.assetID, user: a).failureCode == "MEDIA_TYPE_MISMATCH")
            let mismatched = try await http.create("live_photo", sources: [
                ("original", "preview-image-08.png", "image/png", mediaFixture("preview-image-08.png")),
                ("paired_video", "live-photo.mov", "video/quicktime", mediaFixture("live-photo.mov"))
            ], conversation: chat, user: a)
            for part in mismatched.uploads {
                try await http.upload(part, bytes: mediaFixture(part.role == "original" ? "preview-image-08.png" : "live-photo.mov"), index: 0, user: a)
            }
            #expect(try await http.finish(mismatched.assetID, user: a).failureCode == "INVALID_MEDIA")
            var input = MediaCreateRequest(); input.operationID = UUID().uuidString; input.kind = "live_photo"; input.conversationID = chat.conversationID
            var resource = MediaResourceInput(); resource.role = "original"; resource.filename = "a.jpg"; resource.mimeType = "image/jpeg"; resource.byteCount = 1; resource.sha256 = LocalMediaBlobStore.hash(Data([1])); input.resources = [resource]
            #expect(try await send(app, .POST, "/v1/media/assets/create", input, token: a.accessToken).status == .badRequest)
            input.kind = "image"; resource.byteCount = 25 * 1024 * 1024 + 1; input.resources = [resource]; input.operationID = UUID().uuidString
            #expect(try await send(app, .POST, "/v1/media/assets/create", input, token: a.accessToken).status == .badRequest)
            let pending = try await http.create("file", sources: [("original", "a.bin", "application/octet-stream", bytes)], conversation: chat, user: a)
            var cancel = MediaAssetMutation(); cancel.operationID = UUID().uuidString; cancel.assetID = pending.assetID
            _ = try await http.call("v1/media/assets/cancel", cancel, MediaAssetStatus.self, user: a)
            try await http.upload(pending.uploads[0], bytes: bytes, index: 0, user: a, expected: 409)
            let repeated = try await http.call("v1/media/assets/cancel", cancel, MediaAssetStatus.self, user: a)
            #expect(["cancelled", "deleted"].contains(repeated.state))
            let media = app.storage[MediaServiceKey.self]!
            let reserved = try #require(try await MediaAssetRecord.find(UUID(uuidString: created.assetID)!, on: app.db))
            reserved.reservedBytes = media.limits.accountBytes; try await reserved.update(on: app.db)
            input.kind = "file"; resource.byteCount = 1; input.resources = [resource]; input.operationID = UUID().uuidString
            #expect(try errorCode(await send(app, .POST, "/v1/media/assets/create", input, token: a.accessToken)) == "MEDIA_QUOTA_EXCEEDED")
        }
    }
    @Test func membershipIntervalsAndCrossAccountReferences() async throws {
        try await withMediaHTTP { app, _, http in
            let a = try await auth(app, name: "history_a"), b = try await auth(app, name: "history_b"), c = try await auth(app, name: "history_c")
            var chat = try await group(app, a, [c])
            let bytes = Data("group resource".utf8)
            let created = try await http.create("file", sources: [("original", "test.bin", "application/octet-stream", bytes)], conversation: chat, user: a)
            try await http.upload(created.uploads[0], bytes: bytes, index: 0, user: a)
            let ready = try await http.finish(created.assetID, user: a), resource = ready.asset.resources[0]
            func message(_ user: AuthResponse) -> IMSendRequest { var value = outgoing(chat, user, text: ""); value.contentType = "file"; value.assetIds = [created.assetID]; return value }
            let before = try await http.call("v1/im/messages/send", message(a), IMMessage.self, user: a)
            chat = try await imCall(app, "groups/update", groupChange(chat, action: "add", target: b.userID), IMConversation.self, a)
            let during = try await http.call("v1/im/messages/send", message(a), IMMessage.self, user: a)
            chat = try await imCall(app, "groups/update", groupChange(chat, action: "remove", target: b.userID), IMConversation.self, a)
            let absent = try await http.call("v1/im/messages/send", message(a), IMMessage.self, user: a)
            chat = try await imCall(app, "groups/update", groupChange(chat, action: "add", target: b.userID), IMConversation.self, a)
            for id in [before.messageUuid, absent.messageUuid] {
                var grant = MediaAuthorizeRequest(); grant.resourceID = resource.resourceID; grant.purpose = "message_view"; grant.messageUuid = id
                #expect(try await send(app, .POST, "/v1/media/resources/authorize", grant, token: b.accessToken).status == .notFound)
            }
            _ = try await http.grant(resource, user: b, message: during.messageUuid)
            #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", message(b), token: b.accessToken)) == "MEDIA_NOT_FOUND")
            let other = try await direct(app, a, b)
            var cross = message(a); cross.conversationID = other.conversationID
            #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", cross, token: a.accessToken)) == "MEDIA_NOT_READY")
            #expect(try await IMMessageRecord.query(on: app.db).count() == 3)
            #expect(try await MediaReferenceRecord.query(on: app.db).count() == 3)
        }
    }
    @Test func workerCrashTimeoutAndMissingKey() async throws {
        try await withMediaHTTP { app, _, http in
            let a = try await auth(app, name: "worker_a"), b = try await auth(app, name: "worker_b")
            let chat = try await direct(app, a, b), media = app.storage[MediaServiceKey.self]!
            await media.runtime.stop()
            for (worker, expected) in [("/usr/bin/false", "PROCESSOR_FAILED"), ("timeout", "PROCESSING_TIMEOUT"), ("key", "MEDIA_KEY_UNAVAILABLE")] {
                let bytes = try mediaFixture("preview-image-08.png")
                let created = try await http.create("image", sources: [("original", "image.png", "image/png", bytes)], conversation: chat, user: a)
                try await http.upload(created.uploads[0], bytes: bytes, index: 0, user: a)
                var complete = MediaAssetMutation(); complete.operationID = UUID().uuidString; complete.assetID = created.assetID
                _ = try await http.call("v1/media/assets/complete", complete, MediaAssetStatus.self, user: a)
                var limits = MediaLimits(); limits.processingSeconds = worker == "timeout" ? 0 : 120
                if worker == "key" {
                    let row = try #require(try await MediaResourceRecord.find(UUID(uuidString: created.uploads[0].resourceID)!, on: app.db)); row.wrappedKey = nil; try await row.update(on: app.db)
                }
                let processor = MediaService(accounts: media.accounts, im: media.im, blobs: media.blobs, limits: limits, worker: worker == "timeout" || worker == "key" ? media.worker : worker)
                try await processor.processNext(app.db)
                let status = try await http.status(created.assetID, user: a)
                #expect(status.state == "failed"); #expect(status.failureCode == expected)
                #expect(try FileManager.default.contentsOfDirectory(atPath: media.blobs.work.path).isEmpty)
                #expect(await !processor.leases.active(UUID(uuidString: created.assetID)!))
            }
        }
    }
}
