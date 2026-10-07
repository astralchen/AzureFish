@testable import Server
import Foundation
import Testing
import VaporTesting

@Suite("共享实时协调器", .serialized, .timeLimit(.minutes(1)))
struct IMLiveCoordinatorTests {
    @Test func multipleSocketsShareAccountQueriesAndInvalidSessionClosesAll() async throws {
        try await withServer { app, _ in
            let user = try await auth(app, name: "shared_live")
            let service = try #require(app.storage[MediaServiceKey.self]).im
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try #require(app.http.server.shared.localAddress?.port)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/im/live")!)
            request.setValue("Bearer " + user.accessToken, forHTTPHeaderField: "Authorization")
            let first = session.webSocketTask(with: request), second = session.webSocketTask(with: request)
            first.resume(); second.resume()
            _ = try await first.receive(); _ = try await second.receive()
            let active = await service.live.diagnostics()
            #expect(active.accounts == 1 && active.connections == 2)
            let before = active.queryBatches
            try await Task.sleep(for: .milliseconds(1300))
            let after = await service.live.diagnostics()
            #expect(after.queryBatches - before <= 2, "两个连接仍只执行每账号共享补偿查询")
            var profile = UpdateProfileRequest(); profile.operationID = UUID().uuidString
            profile.expectedProfileVersion = 1; profile.nickname = "共享实时资料更新"
            #expect(try await send(app, .PATCH, "/v1/me", profile, token: user.accessToken).status == .ok)
            for socket in [first, second] {
                let message = try await socket.receive()
                guard case .data(let data) = message else { Issue.record("Expected binary sync hint"); continue }
                #expect(try IMSyncHint(serializedBytes: data).ownProfileVersion == 2)
            }
            var logout = LogoutRequest(); logout.operationID = UUID().uuidString
            _ = try await send(app, .POST, "/v1/auth/logout", logout, token: user.accessToken)
            for socket in [first, second] {
                do { _ = try await socket.receive(); Issue.record("Revoked session still received data") }
                catch { #expect(socket.closeCode == .policyViolation) }
            }
            for _ in 0..<100 {
                if await service.live.diagnostics().connections == 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await service.live.diagnostics().accounts == 0)
            await app.server.shutdown()
        }
    }
}
