#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import AzureFishNetwork

@Suite("原生 WebSocket 随机回环端口", .timeLimit(.minutes(1)))
struct NativeWebSocketTests {
    /// 验证原生 WebSocket 握手、回声、心跳、关闭、重定向和大小限制。
    @Test func handshakeEchoPingCloseRedirectAndLimit() async throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [try #require(Bundle.module.url(forResource: "websocket_server", withExtension: "py", subdirectory: "Fixtures")).path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let port = try #require(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        func request(_ path: String) -> WebSocketHandshake { WebSocketHandshake(url: URL(string: "ws://127.0.0.1:\(port)/\(path)")!) }
        let native = URLSessionWebSocketTransport(security: .debugLoopbackForFictionalData)
        try await native.connect(request("echo"), maximumMessageBytes: 4096)
        try await native.send(.text("fictional text"))
        #expect(try await native.receive() == .text("fictional text"))
        try await native.send(.binary(Data([0, 1, 255])))
        #expect(try await native.receive() == .binary(Data([0, 1, 255])))
        let reading = Task { try await native.receive() }
        // 长连接空闲超过 HTTP 默认的 15 秒后仍可接收 pong 和业务帧。
        try await Task.sleep(nanoseconds: 16_000_000_000)
        try await webSocketTimeout(seconds: 5, clock: SystemNetworkClock(), error: .pongTimeout) { try await native.ping() }
        try await native.send(.text("after-pong"))
        #expect(try await reading.value == .text("after-pong"))
        await native.close()
        for (path, status) in [("redirect", 307), ("unauthorized", 401)] {
            let transport = URLSessionWebSocketTransport(security: .debugLoopbackForFictionalData)
            await #expect(throws: WebSocketError.handshakeRejected(status: status)) {
                try await transport.connect(request(path), maximumMessageBytes: 4096)
            }
            await transport.close()
        }
        let policy = URLSessionWebSocketTransport(security: .debugLoopbackForFictionalData)
        try await policy.connect(request("policy"), maximumMessageBytes: 4096)
        await #expect(throws: WebSocketError.closed(code: 1008)) { try await policy.receive() }
        await policy.close()
        let large = URLSessionWebSocketTransport(security: .debugLoopbackForFictionalData)
        try await large.connect(request("large"), maximumMessageBytes: 4096)
        await #expect(throws: (any Error).self) { try await large.receive() }
        await large.close()
    }

    /// 验证WebSocket 安全策略限制 WS 与 WSS 地址。
    @Test func securityPolicy() throws {
        try TransportSecurityPolicy.httpsOnly.validateWebSocket(URL(string: "wss://example.invalid/live")!)
        for address in ["ws://example.invalid/live", "ws://localhost/live", "wss://user:password@example.invalid", "wss://example.invalid/#token"] {
            #expect(throws: WebSocketError.insecureURL) { try TransportSecurityPolicy.httpsOnly.validateWebSocket(URL(string: address)!) }
        }
        try TransportSecurityPolicy.debugLoopbackForFictionalData.validateWebSocket(URL(string: "ws://127.0.0.1:12345/live")!)
    }
}
#endif
