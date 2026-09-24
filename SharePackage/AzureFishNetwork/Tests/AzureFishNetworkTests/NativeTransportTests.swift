#if os(macOS) && DEBUG
import AzureFishNetwork
import Foundation
import Testing

@Suite("原生 URLSession 回环验证")
struct NativeTransportTests {
    @Test func redirectCacheCookiesLimitsAndCancellation() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [try #require(Bundle.module.url(forResource: "http_server", withExtension: "py", subdirectory: "Fixtures")).path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let portText = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try #require(Int(portText))
        let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
        let transport = URLSessionHTTPTransport(security: .debugLoopbackForFictionalData)
        func request(_ path: String, limit: Int = 1024) -> HTTPRequest {
            HTTPRequest(url: base.appendingPathComponent(path), maximumResponseBytes: limit)
        }
        let first = try await transport.send(request("ok"))
        let second = try await transport.send(request("ok"))
        #expect(first.body != second.body)
        #expect(second.header("X-Received-Cookie") == "none")
        #expect(try await transport.send(request("redirect")).statusCode == 307)
        let afterRedirect = try await transport.send(request("ok"))
        #expect(String(decoding: afterRedirect.body, as: UTF8.self) == "4")
        for path in ["large", "unknown-length"] {
            await #expect(throws: NetworkError.responseTooLarge(limit: 100)) { try await transport.send(request(path, limit: 100)) }
        }
        let slow = request("slow")
        let task = Task { try await transport.send(slow) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        task.cancel()
        do { _ = try await task.value; Issue.record("Native request ignored cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
#endif
