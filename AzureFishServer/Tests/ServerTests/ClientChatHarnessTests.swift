@testable import Server
import Foundation
import Testing
import VaporTesting

/// 只在显式启用时启动隔离服务并运行客户端已编译的测试，不依赖客户端生产模块。
@Suite("客户端好友与加密媒体独立联调", .timeLimit(.minutes(2)))
struct ClientChatHarnessTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AZUREFISH_RUN_CLIENT_CHAT"] == "1"))
    func randomPortClientIntegration() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        do {
            try await configure(app, configuration: .init(directory: fixture.directory, key: fixture.key,
                environmentID: "local-development", bcryptCost: 4))
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let media = try #require(app.storage[MediaServiceKey.self])
            await media.runtime.start(media, app: app)
            let port = try #require(app.http.server.shared.localAddress?.port)
            #expect(port != 8080)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["swift", "test", "--package-path", root.appendingPathComponent("SharePackage/AzureFishChat").path,
                                 "--skip-build", "--filter", "IndependentChatTests"]
            var environment = ProcessInfo.processInfo.environment
            environment["AZUREFISH_CHAT_TEST_PORT"] = String(port)
            let completion = URL(fileURLWithPath: fixture.directory).appendingPathComponent("client-test-completed")
            environment["AZUREFISH_CHAT_TEST_COMPLETION"] = completion.path
            environment.removeValue(forKey: "AZUREFISH_API_LIVE_TEST")
            process.environment = environment
            try process.run()
            let status = await Task.detached { process.waitUntilExit(); return process.terminationStatus }.value
            #expect(status == 0)
            #expect(try String(contentsOf: completion, encoding: .utf8) == "completed")
            await app.server.shutdown()
        } catch { await app.server.shutdown(); try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }
}
