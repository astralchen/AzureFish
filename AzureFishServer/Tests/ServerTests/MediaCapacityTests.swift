@testable import Server
import Crypto
import Darwin
import Foundation
import Testing
import VaporTesting

private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}
@Suite("媒体容量", .serialized)
struct MediaCapacityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AZUREFISH_RUN_MEDIA_CAPACITY"] == "1"))
    func near512MiBResumeAndRange() async throws {
        try await withMediaHTTP { app, _, http in
            var user = try await auth(app, name: "capacity_a")
            let peer = try await auth(app, name: "capacity_b"), chat = try await direct(app, user, peer)
            let chunk = Data(repeating: 113, count: MediaLimits.chunk), last = Data(repeating: 114, count: MediaLimits.chunk - 37)
            var hash = SHA256(); for _ in 0..<127 { hash.update(data: chunk) }; hash.update(data: last)
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            var input = MediaCreateRequest(); input.operationID = UUID().uuidString; input.conversationID = chat.conversationID; input.kind = "file"
            var resource = MediaResourceInput(); resource.role = "original"; resource.filename = "capacity.bin"; resource.mimeType = "application/octet-stream"
            resource.byteCount = 512 * 1024 * 1024 - 37; resource.sha256 = digest; input.resources = [resource]
            let created = try await http.call("v1/media/assets/create", input, MediaAssetStatus.self, user: user), upload = created.uploads[0]
            let baseline = residentBytes(); var peak = baseline
            for index in (0..<128).reversed() {
                try await http.upload(upload, bytes: index == 127 ? last : chunk, index: index, user: user)
                peak = max(peak, residentBytes())
                if index == 64 {
                    let status = try await http.status(created.assetID, user: user); #expect(status.uploads[0].completedParts == Array(64...127).map(Int32.init))
                    user = try decode(AuthResponse.self, await send(app, .POST, "/v1/auth/refresh", refresh(user.refreshToken)))
                    try await http.upload(upload, bytes: chunk, index: 64, user: user)
                }
            }
            print("MEDIA CAPACITY upload resident=\(residentBytes())")
            let ready = try await http.finish(created.assetID, user: user); #expect(ready.state == "ready")
            print("MEDIA CAPACITY ready resident=\(residentBytes())")
            var message = outgoing(chat, user, text: ""); message.contentType = "file"; message.assetIds = [created.assetID]
            let sent = try await http.call("v1/im/messages/send", message, IMMessage.self, user: user)
            let stored = try #require(ready.asset.resources.first), grant = try await http.grant(stored, user: peer, message: sent.messageUuid)
            var downloaded = SHA256()
            for index in 0..<128 {
                let start = Int64(index * MediaLimits.chunk), end = min(stored.byteCount - 1, start + Int64(MediaLimits.chunk) - 1)
                let (bytes, response) = try await http.raw("GET", "v1/media/resources/\(stored.resourceID)/content", token: peer.accessToken,
                    headers: ["X-Media-Grant": grant.token, "Range": "bytes=\(start)-\(end)", "If-Range": grant.etag])
                #expect(response.statusCode == 206); #expect(bytes.count == Int(end - start + 1)); downloaded.update(data: bytes)
                peak = max(peak, residentBytes())
            }
            #expect(downloaded.finalize().map { String(format: "%02x", $0) }.joined() == digest)
            #expect(baseline > 0); #expect(peak < baseline + 256 * 1024 * 1024)
            print("MEDIA CAPACITY: bytes=\(stored.byteCount), resident baseline=\(baseline), peak=\(peak)")
        }
    }
}
