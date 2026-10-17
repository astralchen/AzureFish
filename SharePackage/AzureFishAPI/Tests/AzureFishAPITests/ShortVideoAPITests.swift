import Foundation
import Testing
import AzureFishNetwork
import AzureFishNetworkTestSupport
import AzureFishProtocol
import SwiftProtobuf
@testable import AzureFishAPI

@Suite("短视频客户端协议")
struct ShortVideoAPITests {
    private func manager(_ transport: MockHTTPTransport) async throws -> APISessionManager {
        let environment = try APIEnvironment(identifier: "short-video-test", baseURL: URL(string: "https://example.invalid")!)
        let manager = APISessionManager(api: AccountAPI(environment: environment, transport: transport), store: MemorySessionStore())
        try await manager.install(SessionCredentials(environmentID: environment.identifier, userID: UUID(), deviceID: UUID(), sessionID: UUID(),
            accessToken: SessionToken(rawValue: String(repeating: "a", count: 43)), accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            refreshToken: SessionToken(rawValue: String(repeating: "r", count: 43)), refreshExpiresAt: Date(timeIntervalSince1970: 1_902_000_000), refreshGeneration: 1))
        return manager
    }
    @Test func manualRetryKeepsCommentAndOperationIdentity() async throws {
        let transport = MockHTTPTransport { _, _ in
            var video = ShortVideo(); video.videoID = "pixabay:1"; video.commentCount = 1
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try video.serializedData())
        }
        let api = ShortVideoAPI(session: try await manager(transport))
        let id = UUID(), operation = UUID()
        for _ in 0..<2 {
            let result = try await api.comment("pixabay:1", id: id, text: "虚构评论", operation: operation)
            #expect(result.commentCount == 1)
        }
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url.path == "/v1/short-videos/comments/create")
        #expect(requests[0].body == requests[1].body)
        let input = try ShortVideoCommentRequest(serializedBytes: requests[0].body ?? Data())
        #expect(input.operationID == operation.uuidString.lowercased() && input.commentID == id.uuidString.lowercased())
    }
    @Test func missingSourceKeyRemainsRecognizable() async throws {
        let transport = MockHTTPTransport { _, _ in
            var error = ApiError(); error.code = "SHORT_VIDEO_SOURCE_UNCONFIGURED"
            return HTTPResponse(statusCode: 503, headers: ["Content-Type": "application/protobuf"], body: try error.serializedData())
        }
        let api = ShortVideoAPI(session: try await manager(transport))
        do { _ = try await api.list(); Issue.record("缺失 Key 未返回错误") }
        catch APIClientError.service(let failure) { #expect(failure.code == .shortVideoSourceUnconfigured) }
    }
}
