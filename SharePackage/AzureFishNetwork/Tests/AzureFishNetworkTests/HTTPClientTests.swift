import Foundation
import AzureFishNetwork
import AzureFishNetworkTestSupport
import Testing

@Suite("HTTP 传输策略")
struct HTTPClientTests {
    private let url = URL(string: "https://example.invalid/v1/auth/register")!

    @Test func writeReplayUsesSameBytesAndNewRequestID() async throws {
        let transport = MockHTTPTransport { _, attempt in
            if attempt == 1 { throw URLError(.networkConnectionLost) }
            return HTTPResponse(statusCode: 201)
        }
        let client = HTTPClient(transport: transport, waitBeforeRetry: {})
        let request = HTTPRequest(url: url, method: .post, headers: ["Authorization": "Bearer fictional"],
                                  body: Data([1, 2, 3]), replayPolicy: .idempotentWriteOnce(operationID: UUID()))
        #expect(try await client.send(request).statusCode == 201)
        let history = await transport.requests
        #expect(history.count == 2)
        #expect(history[0].body == history[1].body)
        #expect(history[0].headers["Authorization"] == history[1].headers["Authorization"])
        #expect(history[0].headers["X-Request-ID"] != history[1].headers["X-Request-ID"])
    }

    @Test func retryIsBoundedAndOptIn() async throws {
        let transport = MockHTTPTransport { _, _ in throw URLError(.timedOut) }
        let client = HTTPClient(transport: transport, waitBeforeRetry: {})
        do { _ = try await client.send(HTTPRequest(url: url, method: .post, body: Data())) }
        catch { #expect(error as? NetworkError == .transport(code: .timedOut)) }
        #expect(await transport.requests.count == 1)
        do { _ = try await client.send(HTTPRequest(url: url, replayPolicy: .readOnce)) }
        catch { #expect(error as? NetworkError == .transport(code: .timedOut)) }
        #expect(await transport.requests.count == 3)
    }

    @Test func httpAndCertificateErrorsAreNotRetried() async throws {
        let transport = MockHTTPTransport { _, count in
            if count == 1 { return HTTPResponse(statusCode: 503) }
            throw URLError(.serverCertificateUntrusted)
        }
        let client = HTTPClient(transport: transport, waitBeforeRetry: {})
        #expect(try await client.send(HTTPRequest(url: url, replayPolicy: .readOnce)).statusCode == 503)
        do { _ = try await client.send(HTTPRequest(url: url, replayPolicy: .readOnce)) }
        catch { #expect(error as? NetworkError == .transport(code: .serverCertificateUntrusted)) }
        #expect(await transport.requests.count == 2)
    }

    @Test func validatesURLHeadersAndResponseLimit() async throws {
        let transport = MockHTTPTransport { _, _ in HTTPResponse(statusCode: 200, body: Data(repeating: 1, count: 11)) }
        let client = HTTPClient(transport: transport)
        for value in ["http://example.invalid", "file:///tmp/test", "https://user:pass@example.invalid", "https://example.invalid/#fragment"] {
            await #expect(throws: (any Error).self) { try await client.send(HTTPRequest(url: URL(string: value)!)) }
        }
        await #expect(throws: NetworkError.invalidRequest) {
            try await client.send(HTTPRequest(url: url, headers: ["Authorization": "a\r\nb"]))
        }
        #expect(await transport.requests.isEmpty)
        await #expect(throws: NetworkError.responseTooLarge(limit: 10)) {
            try await client.send(HTTPRequest(url: url, maximumResponseBytes: 10, replayPolicy: .readOnce))
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func cancellationIsNotRetried() async throws {
        let transport = MockHTTPTransport { _, _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return HTTPResponse(statusCode: 200)
        }
        let client = HTTPClient(transport: transport, waitBeforeRetry: {})
        let request = HTTPRequest(url: url, replayPolicy: .readOnce)
        let task = Task { try await client.send(request) }
        while await transport.requests.isEmpty { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation was ignored") }
        catch { #expect(error is CancellationError) }
        #expect(await transport.requests.count == 1)
    }

    @Test func debugLoopbackIsRestricted() throws {
        let policy = TransportSecurityPolicy.debugLoopbackForFictionalData
        #expect(throws: NetworkError.insecureURL) { try policy.validate(URL(string: "http://192.168.1.2")!) }
        #expect(throws: NetworkError.insecureURL) { try policy.validate(URL(string: "http://localhost.example.invalid")!) }
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        try policy.validate(URL(string: "http://127.0.0.1:8080")!)
        #else
        #expect(throws: NetworkError.insecureURL) { try policy.validate(URL(string: "http://127.0.0.1:8080")!) }
        #endif
    }

    @Test func descriptionsRedactContent() {
        let request = HTTPRequest(url: url, method: .post, headers: ["Authorization": "secret"], body: Data("secret".utf8))
        let response = HTTPResponse(statusCode: 200, headers: ["X-Secret": "secret"], body: Data("secret".utf8))
        #expect(!String(reflecting: request).contains("secret"))
        #expect(!String(reflecting: response).contains("secret"))
    }
}
