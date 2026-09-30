import AzureFishNetwork
import AzureFishProtocol
import CryptoKit
import Foundation
import SwiftProtobuf

public struct ChatMediaInput: Codable, Sendable {
    /// 资源在资产中的用途，例如 original 或 thumbnail。
    public let role: String
    /// 资源文件名，仅为元数据，不是本地文件路径。
    public let filename: String
    /// 资源的 MIME 类型字符串。
    public let mime: String
    /// 资源完整长度，单位为字节。
    public let bytes: Int64
    /// 完整资源内容的 SHA-256 十六进制摘要。
    public let sha256: String
    /// 保存上传资源的元数据和摘要；用途默认 original，不读取文件或校验摘要。
    public init(role: String = "original", filename: String, mime: String, bytes: Int64, sha256: String) {
        self.role = role
        self.filename = filename
        self.mime = mime
        self.bytes = bytes
        self.sha256 = sha256
    }
}
public struct ChatMediaCapabilities: Sendable {
    /// 服务端支持的上传分块字节数。
    public let chunkBytes: Int64
    /// 单张图片允许的最大字节数。
    public let imageBytes: Int64
    /// 单段视频允许的最大字节数。
    public let videoBytes: Int64
    /// 单个文件允许的最大字节数。
    public let fileBytes: Int64
    /// 单段音频允许的最大字节数。
    public let audioBytes: Int64
    /// 一个媒体组允许的最大条目数。
    public let groupItems: Int32
    /// 一个媒体组允许的最大总字节数。
    public let groupBytes: Int64
    /// 单段音频允许的最大时长，单位为毫秒。
    public let audioMaxDuration: Int64
    /// 服务端媒体处理器是否可用。
    public let available: Bool
    /// 将协议响应映射为媒体能力限制业务值，保留服务端字段和集合顺序，不执行网络或持久化。
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
    /// 临时下载授权原文，仅供构造 X-Media-Grant 请求头，不得持久化或记录。
    let token: String
    /// 获授权下载的服务端资源身份。
    public let resource: String
    /// 下载范围请求必须匹配的资源实体标记。
    public let etag: String
    /// 获授权资源的完整字节数。
    public let bytes: Int64
    /// 授权到期时间，采用 Unix 毫秒时间戳。
    public let expiresAt: Int64
    /// 隐藏临时授权内容的固定说明。
    public var description: String { "ChatDownloadGrant(<redacted>)" }
    /// 将协议响应映射为临时下载授权业务值，保留服务端字段和集合顺序，不执行网络或持久化。
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
    /// 控制请求和二进制传输共享的会话管理器。
    public let session: APISessionManager
    /// 承载 Protobuf 媒体控制请求的 IM API 适配器。
    private let im: IMAPI
    /// 执行上传、下载分块的 HTTP 客户端，沿用会话环境安全策略。
    private let client: HTTPClient
    /// 绑定会话管理器及可选二进制传输；transport 仅影响分块请求，控制请求通过会话 API 执行。
    public init(session: APISessionManager, transport: (any HTTPTransport)? = nil) {
        self.session = session
        im = IMAPI(session: session)
        client = HTTPClient(transport: transport, security: session.environment.security)
    }
    /// 获取服务端媒体处理可用状态及大小、时长和组数量限制。
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
    /// 登记指定会话的媒体资源清单并获取上传状态；同一次创建重试须复用 operationID。
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
    /// 读取指定媒体资产的处理状态和已上传分块信息。
    public func status(_ asset: String) async throws -> ChatAssetStatus {
        var input = MediaAssetRequest()
        input.assetID = asset
        return try await im.call("v1/media/assets/status", input, as: MediaAssetStatus.self, map: ChatAssetStatus.init)
    }
    /// 按 cancel 选择提交完成或取消资产；重复执行同一动作须复用 operationID。
    public func finish(_ asset: String, cancel: Bool = false, operationID: UUID) async throws -> ChatAssetStatus {
        var input = MediaAssetMutation()
        input.assetID = asset
        input.operationID = operationID.uuidString.lowercased()
        return try await im.call(
            "v1/media/assets/" + (cancel ? "cancel" : "complete"), input, as: MediaAssetStatus.self, id: operationID,
            map: ChatAssetStatus.init)
    }
    /// 上传一个分块并校验响应中的索引、长度及 SHA-256 摘要。
    ///
    /// - Parameters:
    ///   - upload: 可解析为 UUID 的服务端上传身份。
    ///   - index: 从 0 开始的分块序号。
    ///   - bytes: 非空分块，最多 4 MiB。
    /// - Throws: 输入无效、网络或业务失败，以及响应与上传内容不一致的错误。
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
    /// 为资源请求短期下载授权；message 为 nil 时申请草稿预览权限，否则申请消息查看权限。
    public func authorize(_ resource: String, message: String?) async throws -> ChatDownloadGrant {
        var input = MediaAuthorizeRequest()
        input.resourceID = resource
        input.messageUuid = message ?? ""
        input.purpose = message == nil ? "draft_preview" : "message_view"
        return try await im.call(
            "v1/media/resources/authorize", input, as: MediaDownloadGrant.self, map: ChatDownloadGrant.init)
    }
    /// 按授权下载指定字节范围，并校验 206、ETag、Content-Range 及实际长度。
    ///
    /// 接收时为错误正文保留最多 64 KiB，短分块的认证失败仍可触发共享刷新。
    ///
    /// - Parameters:
    ///   - grant: 与目标资源对应的内存授权。
    ///   - offset: 从 0 开始的字节偏移。
    ///   - count: 正数读取长度，最多 4 MiB，范围不得超过 grant.bytes。
    /// - Returns: 严格等于 count 字节的响应正文。
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
    /// 在共享会话授权下发送分块请求，将已知服务端错误和网络错误映射为 APIClientError。
    private func binary(path: String, method: HTTPMethod, headers: [String: String], body: Data?, max: Int) async throws
        -> HTTPResponse
    {
        let url = session.environment.url(path: path)
        let client = client
        let maximumErrorBytes = 64 * 1024
        return try await session.authorized { credentials in
            var headers = headers
            headers["Authorization"] = "Bearer " + credentials.accessToken.rawValue
            let response: HTTPResponse
            do {
                response = try await client.send(
                    HTTPRequest(
                        url: url, method: method, headers: headers, body: body, timeout: 60,
                        maximumResponseBytes: Swift.max(max, maximumErrorBytes)))
            } catch let error as NetworkError { throw APIClientError.network(error) }
            if !(200..<300).contains(response.statusCode) {
                guard response.body.count <= maximumErrorBytes else {
                    throw APIClientError.network(.responseTooLarge(limit: maximumErrorBytes))
                }
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
