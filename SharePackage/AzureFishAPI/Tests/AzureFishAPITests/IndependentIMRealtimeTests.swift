#if os(macOS) && DEBUG
import Foundation
import Testing
import AzureFishNetwork
import AzureFishAPI

@Suite("独立随机端口 IM 真服务", .timeLimit(.minutes(1)))
struct IndependentIMRealtimeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AZUREFISH_REALTIME_TEST_PORT"] != nil))
    func hintsRefreshAndLogout() async throws {
        let port = try #require(Int(ProcessInfo.processInfo.environment["AZUREFISH_REALTIME_TEST_PORT"] ?? ""))
        #expect(port != 8080)
        guard port != 8080 else { return }
        let api = AccountAPI(environment: try .localTesting(port: port))
        let registration = try api.prepareRegistration(operationID: UUID(), deviceID: UUID(),
            accountName: "realtime_" + UUID().uuidString.prefix(8).lowercased(), password: "Fictional-Password-123", nickname: "实时虚构测试")
        let session = try await api.execute(registration)
        let manager = APISessionManager(api: api, store: MemorySessionStore())
        try await manager.install(session.credentials)
        let client = IMRealtimeClient(sessionManager: manager)
        let seen = SignalCollector()
        let stream = await client.syncSignals()
        let observer = Task { for await signal in stream { await seen.append(signal) } }
        defer { observer.cancel() }
        await client.start()
        try await poll { await seen.values.contains { $0.hint != nil && $0.session.refreshGeneration == 1 } }
        #expect(await client.currentState == .connected)
        let renewed = try await manager.refresh()
        #expect(renewed.refreshGeneration == 2)
        try await poll { await seen.values.contains { $0.hint != nil && $0.session.refreshGeneration == 2 } }
        // 独立旧 Bearer 连接验证服务端撤销行为，不仅检查客户端主动关闭。
        let witness = URLSessionWebSocketTransport(security: .debugLoopbackForFictionalData)
        let request = WebSocketHandshake(url: URL(string: "ws://127.0.0.1:\(port)/v1/im/live")!,
                                        headers: ["Authorization": "Bearer \(renewed.accessToken.rawValue)"])
        try await witness.connect(request, maximumMessageBytes: 4096)
        _ = try await witness.receive()
        try await manager.logout()
        try await poll { await client.currentState == .stopped }
        await #expect(throws: WebSocketError.closed(code: 1008)) { try await witness.receive() }
        await witness.close()
        let rejected = URLSessionWebSocketTransport(security: .debugLoopbackForFictionalData)
        await #expect(throws: WebSocketError.handshakeRejected(status: 401)) {
            try await rejected.connect(request, maximumMessageBytes: 4096)
        }
        await rejected.close(); await client.stop()
        #expect(await manager.state.sessionID == nil)
        if let path = ProcessInfo.processInfo.environment["AZUREFISH_REALTIME_TEST_COMPLETION"] {
            try Data("completed".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    private func poll(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        throw WebSocketError.requestTimeout
    }
}
private actor SignalCollector {
    var values: [IMRealtimeSignal] = []
    func append(_ value: IMRealtimeSignal) { values.append(value) }
}
#endif
