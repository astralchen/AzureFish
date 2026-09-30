import Foundation
import Testing
import AzureFishNetwork
import AzureFishNetworkTestSupport
import AzureFishProtocol
import SwiftProtobuf
@testable import AzureFishAPI

private struct MediaFixture: Sendable {
    let user = UUID(), device = UUID(), session = UUID(), resource = UUID().uuidString.lowercased()
    let environment = try! APIEnvironment(identifier: "media-test", baseURL: URL(string: "https://example.invalid")!)
    let offset: Int64 = 4 * 1024 * 1024

    func credentials(_ generation: Int64 = 1) throws -> SessionCredentials {
        try SessionCredentials(environmentID: environment.identifier, userID: user, deviceID: device, sessionID: session,
            accessToken: SessionToken(rawValue: String(repeating: generation == 1 ? "a" : "b", count: 43)),
            accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            refreshToken: SessionToken(rawValue: String(repeating: generation == 1 ? "r" : "s", count: 43)),
            refreshExpiresAt: Date(timeIntervalSince1970: 1_902_000_000), refreshGeneration: generation)
    }

    func auth() throws -> HTTPResponse {
        let credentials = try credentials(2)
        var auth = AuthResponse(), profile = AzureFishProtocol.UserProfile()
        profile.userID = user.uuidString.lowercased(); profile.accountName = "fictional_media"
        profile.nickname = "虚构"; profile.profileVersion = 1
        profile.createdAtMs = 1_800_000_000_000; profile.updatedAtMs = profile.createdAtMs
        auth.environmentID = environment.identifier; auth.userID = profile.userID; auth.profile = profile
        auth.deviceID = device.uuidString.lowercased(); auth.sessionID = session.uuidString.lowercased()
        auth.accessToken = credentials.accessToken.rawValue; auth.refreshToken = credentials.refreshToken.rawValue
        auth.accessExpiresAtMs = 1_900_000_000_000; auth.refreshExpiresAtMs = 1_902_000_000_000; auth.refreshGeneration = 2
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try auth.serializedData())
    }

    func grant(count: Int) -> ChatDownloadGrant {
        var value = MediaDownloadGrant()
        value.resourceID = resource; value.token = "fictional-grant"; value.etag = "\"fictional-etag\""
        value.byteCount = offset + Int64(count); value.expiresAtMs = 1_900_000_000_000
        return ChatDownloadGrant(value)
    }

    func success(count: Int) -> HTTPResponse {
        HTTPResponse(statusCode: 206, headers: ["ETag": "\"fictional-etag\"",
            "Content-Range": "bytes \(offset)-\(offset + Int64(count) - 1)/\(offset + Int64(count))"],
            body: Data(repeating: 7, count: count))
    }

    func failure(status: Int, code: String) throws -> HTTPResponse {
        var error = ApiError(); error.code = code; error.requestID = UUID().uuidString.lowercased()
        return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/protobuf", "Retry-After": "60"],
            body: try error.serializedData())
    }
}

@Suite("媒体下载错误边界")
struct MediaAPITests {
    /// 错误正文长于尾块时，401 仍刷新一次并保持原下载范围。
    @Test(arguments: [1, 31])
    func shortTailRefreshesAndRetriesSameRange(count: Int) async throws {
        let fixture = MediaFixture()
        let control = MockHTTPTransport { _, _ in try fixture.auth() }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: control), store: MemorySessionStore())
        try await manager.install(fixture.credentials())
        let transport = MockHTTPTransport { _, number in
            number == 1 ? try fixture.failure(status: 401, code: "UNAUTHENTICATED") : fixture.success(count: count)
        }
        let api = MediaAPI(session: manager, transport: transport)
        #expect(try await api.download(fixture.grant(count: count), offset: fixture.offset, count: count) == Data(repeating: 7, count: count))
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].headers["Range"] == requests[1].headers["Range"])
        #expect(requests[0].headers["X-Media-Grant"] == requests[1].headers["X-Media-Grant"])
        #expect(requests[0].headers["Authorization"] != requests[1].headers["Authorization"])
        #expect(await control.requests.count == 1)
        #expect(await control.requests.first?.url.path == "/v1/auth/refresh")
    }

    /// 权限与限流错误正确分类，不触发刷新。
    @Test(arguments: [403, 429])
    func shortDownloadPreservesServiceFailure(status: Int) async throws {
        let fixture = MediaFixture()
        let control = MockHTTPTransport { _, _ in try fixture.auth() }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: control), store: MemorySessionStore())
        try await manager.install(fixture.credentials())
        let code: APIErrorCode = status == 403 ? .mediaNotFound : .rateLimited
        let transport = MockHTTPTransport { _, _ in try fixture.failure(status: status, code: code.rawValue) }
        do {
            _ = try await MediaAPI(session: manager, transport: transport).download(fixture.grant(count: 1), offset: fixture.offset, count: 1)
            Issue.record("业务错误未传播")
        } catch APIClientError.service(let failure) {
            #expect(failure.statusCode == status && failure.code == code)
            #expect(failure.requestID != nil && failure.retryAfterSeconds == 60)
        }
        #expect(await transport.requests.count == 1)
        #expect(await control.requests.isEmpty)
    }

    /// 大分块也不能让超过 64 KiB 的错误正文进入 Protobuf 解码。
    @Test(arguments: [1, 128 * 1024])
    func oversizedErrorIsRejected(count: Int) async throws {
        let fixture = MediaFixture()
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment), store: MemorySessionStore())
        try await manager.install(fixture.credentials())
        let transport = MockHTTPTransport { _, _ in
            HTTPResponse(statusCode: 401, headers: ["Content-Type": "application/protobuf"], body: Data(repeating: 0, count: 64 * 1024 + 1))
        }
        await #expect(throws: APIClientError.network(.responseTooLarge(limit: 64 * 1024))) {
            try await MediaAPI(session: manager, transport: transport).download(fixture.grant(count: count), offset: fixture.offset, count: count)
        }
    }

    /// 扩大的接收容量不放宽成功下载的状态、实体标记、范围或长度契约。
    @Test(arguments: ["status", "etag", "range", "length"])
    func invalidSuccessIsRejected(field: String) async throws {
        let fixture = MediaFixture()
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment), store: MemorySessionStore())
        try await manager.install(fixture.credentials())
        let transport = MockHTTPTransport { _, _ in
            let original = fixture.success(count: 1)
            var headers = original.headers
            if field == "etag" { headers["ETag"] = "wrong" }
            if field == "range" { headers["Content-Range"] = "bytes 0-0/1" }
            return HTTPResponse(statusCode: field == "status" ? 200 : 206, headers: headers,
                body: field == "length" ? Data([7, 7]) : original.body)
        }
        await #expect(throws: APIClientError.invalidResponse) {
            try await MediaAPI(session: manager, transport: transport).download(fixture.grant(count: 1), offset: fixture.offset, count: 1)
        }
    }
}
