@testable import Server
import Fluent
import Foundation
import SQLKit
import Testing
import VaporTesting

@Suite("媒体事务与传输竞态", .serialized)
struct MediaRaceTests {
    @Test func slowUploadAndCancellation() async throws {
        try await withMediaHTTP { app, _, http in
            let a = try await auth(app, name: "slow_a"), b = try await auth(app, name: "slow_b"), chat = try await direct(app, a, b)
            for cancelled in [false, true] {
                let bytes = Data(repeating: 115, count: MediaLimits.chunk)
                let created = try await http.create("file", sources: [("original", "slow.bin", "application/octet-stream", bytes)], conversation: chat, user: a)
                var cancel = MediaAssetMutation(); cancel.operationID = UUID().uuidString; cancel.assetID = created.assetID
                let control = try cancelled ? cancel.serializedData() : outgoing(chat, a).serializedData()
                let config: [String: Any] = ["port": http.base.port!, "upload": created.uploads[0].uploadID, "token": a.accessToken,
                    "control_path": cancelled ? "/v1/media/assets/cancel" : "/v1/im/messages/send", "control_body": control.base64EncodedString(), "expected": cancelled ? 409 : 200]
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                process.arguments = [root.appendingPathComponent("Scripts/media-slow-transfer.py").path]
                let pipe = Pipe(); process.standardInput = pipe
                let data = try JSONSerialization.data(withJSONObject: config)
                try await app.storage[MediaServiceKey.self]!.blobs.io {
                    try process.run(); try pipe.fileHandleForWriting.write(contentsOf: data); try pipe.fileHandleForWriting.close(); process.waitUntilExit()
                }
                #expect(process.terminationStatus == 0)
                let status = try await http.status(created.assetID, user: a)
                #expect(cancelled ? ["cancelled", "deleted"].contains(status.state) : status.uploads[0].completedParts == [0])
            }
        }
    }
    @Test func databaseFailureRemovesUncommittedCiphertext() async throws {
        try await withMediaHTTP { app, _, http in
            let a = try await auth(app, name: "rollback_a"), b = try await auth(app, name: "rollback_b"), chat = try await direct(app, a, b)
            let bytes = Data("rollback".utf8)
            let created = try await http.create("file", sources: [("original", "a.bin", "application/octet-stream", bytes)], conversation: chat, user: a)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("CREATE TRIGGER media_test_failure BEFORE INSERT ON media_parts BEGIN SELECT RAISE(ABORT, 'injected'); END").run()
            try await http.upload(created.uploads[0], bytes: bytes, index: 0, user: a, expected: 500)
            #expect(try await http.status(created.assetID, user: a).uploads[0].completedParts.isEmpty)
            let directory = app.storage[MediaServiceKey.self]!.blobs.root.appendingPathComponent(created.uploads[0].resourceID)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            try await sql.raw("DROP TRIGGER media_test_failure").run()
            try await http.upload(created.uploads[0], bytes: bytes, index: 0, user: a)
            #expect(try await http.finish(created.assetID, user: a).state == "ready")
        }
    }
}
