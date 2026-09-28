import AzureFishNetwork
import AzureFishProtocol
import CryptoKit
import Foundation
import SwiftProtobuf

public struct ChatMediaInput: Codable, Sendable {
    public let role: String
    public let filename: String
    public let mime: String
    public let bytes: Int64
    public let sha256: String
    public init(role: String = "original", filename: String, mime: String, bytes: Int64, sha256: String) {
        self.role = role
        self.filename = filename
        self.mime = mime
        self.bytes = bytes
        self.sha256 = sha256
    }
}
public struct ChatMediaCapabilities: Sendable {
    public let chunkBytes: Int64
    public let imageBytes: Int64
    public let videoBytes: Int64
    public let fileBytes: Int64
    public let audioBytes: Int64
    public let groupItems: Int32
    public let groupBytes: Int64
    public let audioMaxDuration: Int64
    public let available: Bool
    init(_ v: MediaCapabilities) {
        chunkBytes = v.chunkBytes
        imageBytes = v.imageMaxBytes
        videoBytes = v.videoMaxBytes
        fileBytes = v.fileMaxBytes
        audioBytes = v.audioMaxBytes
        groupItems = v.groupMaxItems
        groupBytes = v.groupMaxBytes
        audioMaxDuration = v.audioMaxDurationMs
        available = v.processorAvailable
    }
}
/// 只在内存使用的下载授权，描述信息始终脱敏。
public struct ChatDownloadGrant: Sendable, CustomStringConvertible {
    let token: String
    public let resource: String
    public let etag: String
    public let bytes: Int64
    public let expiresAt: Int64
    public var description: String { "ChatDownloadGrant(<redacted>)" }
    init(_ v: MediaDownloadGrant) {
        token = v.token
        resource = v.resourceID
        etag = v.etag
        bytes = v.byteCount
        expiresAt = v.expiresAtMs
    }
}
/// 控制请求使用 Protobuf；上传和下载每次最多持有一个 4 MiB 分块。
public struct MediaAPI: Sendable {
    public let session: APISessionManager
    private let im: IMAPI
    private let client: HTTPClient
    public init(session: APISessionManager, transport: (any HTTPTransport)? = nil) {
        self.session = session
        im = IMAPI(session: session)
        client = HTTPClient(transport: transport, security: session.environment.security)
    }
    public func capabilities() async throws -> ChatMediaCapabilities {
        let credentials = try await session.credentials()
        let operation = AccountOperation<ChatMediaCapabilities>(
            operationID: nil, environment: session.environment,
            path: "v1/media/capabilities", method: .get, body: nil, expectedStatus: 200,
            authorization: SessionIdentity(credentials)
        ) {
            ChatMediaCapabilities(try MediaCapabilities(serializedBytes: $0))
        }
        return try await session.execute(operation)
    }
    public func create(conversation: String, kind: String, resources: [ChatMediaInput], operationID: UUID) async throws
        -> ChatAssetStatus
    {
        var input = MediaCreateRequest()
        input.operationID = operationID.uuidString.lowercased()
        input.conversationID = conversation
        input.kind = kind
        input.resources = resources.map { value in
            var source = MediaResourceInput()
            source.role = value.role
            source.filename = value.filename
            source.mimeType = value.mime
            source.byteCount = value.bytes
            source.sha256 = value.sha256
            return source
        }
        return try await im.call(
            "v1/media/assets/create", input, as: MediaAssetStatus.self, id: operationID, map: ChatAssetStatus.init)
    }
    public func status(_ asset: String) async throws -> ChatAssetStatus {
        var input = MediaAssetRequest()
        input.assetID = asset
        return try await im.call("v1/media/assets/status", input, as: MediaAssetStatus.self, map: ChatAssetStatus.init)
    }
    public func finish(_ asset: String, cancel: Bool = false, operationID: UUID) async throws -> ChatAssetStatus {
        var input = MediaAssetMutation()
        input.assetID = asset
        input.operationID = operationID.uuidString.lowercased()
        return try await im.call(
            "v1/media/assets/" + (cancel ? "cancel" : "complete"), input, as: MediaAssetStatus.self, id: operationID,
            map: ChatAssetStatus.init)
    }
    public func upload(_ upload: String, index: Int, bytes: Data) async throws {
        guard UUID(uuidString: upload) != nil, index >= 0, !bytes.isEmpty, bytes.count <= 4 * 1024 * 1024 else {
            throw APIClientError.invalidRequest
        }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let response = try await binary(
            path: "v1/media/uploads/\(upload)/parts/\(index)", method: .put,
            headers: ["Content-Type": "application/octet-stream", "X-Content-SHA256": hash], body: bytes, max: 64 * 1024
        )
        guard response.statusCode == 200 else {
            throw APIClientError.unexpectedHTTPStatus(statusCode: response.statusCode, requestID: nil)
        }
        let part = try MediaPartResponse(serializedBytes: response.body)
        guard part.sha256 == hash, part.byteCount == bytes.count, part.index == index else {
            throw APIClientError.invalidResponse
        }
    }
    public func authorize(_ resource: String, message: String?) async throws -> ChatDownloadGrant {
        var input = MediaAuthorizeRequest()
        input.resourceID = resource
        input.messageUuid = message ?? ""
        input.purpose = message == nil ? "draft_preview" : "message_view"
        return try await im.call(
            "v1/media/resources/authorize", input, as: MediaDownloadGrant.self, map: ChatDownloadGrant.init)
    }
    public func download(_ grant: ChatDownloadGrant, offset: Int64, count: Int) async throws -> Data {
        guard UUID(uuidString: grant.resource) != nil, offset >= 0, count > 0, count <= 4 * 1024 * 1024,
            offset + Int64(count) <= grant.bytes
        else { throw APIClientError.invalidRequest }
        let response = try await binary(
            path: "v1/media/resources/\(grant.resource)/content", method: .get,
            headers: [
                "X-Media-Grant": grant.token, "Range": "bytes=\(offset)-\(offset + Int64(count) - 1)",
                "If-Range": grant.etag,
            ], body: nil, max: count)
        guard response.statusCode == 206, response.header("ETag") == grant.etag,
            response.header("Content-Range") == "bytes \(offset)-\(offset + Int64(count) - 1)/\(grant.bytes)",
            response.body.count == count
        else { throw APIClientError.invalidResponse }
        return response.body
    }
    private func binary(path: String, method: HTTPMethod, headers: [String: String], body: Data?, max: Int) async throws
        -> HTTPResponse
    {
        let url = session.environment.url(path: path)
        let client = client
        return try await session.authorized { credentials in
            var headers = headers
            headers["Authorization"] = "Bearer " + credentials.accessToken.rawValue
            let response: HTTPResponse
            do {
                response = try await client.send(
                    HTTPRequest(
                        url: url, method: method, headers: headers, body: body, timeout: 60, maximumResponseBytes: max))
            } catch let error as NetworkError { throw APIClientError.network(error) }
            if !(200..<300).contains(response.statusCode) {
                if let error = try? ApiError(serializedBytes: response.body) {
                    throw APIClientError.service(
                        APIServiceFailure(
                            statusCode: response.statusCode, code: APIErrorCode(rawValue: error.code) ?? .unknown,
                            field: nil, requestID: UUID(uuidString: error.requestID),
                            retryAfterSeconds: response.header("Retry-After").flatMap(Int.init)))
                }
                throw APIClientError.unexpectedHTTPStatus(statusCode: response.statusCode, requestID: nil)
            }
            return response
        }
    }
}
