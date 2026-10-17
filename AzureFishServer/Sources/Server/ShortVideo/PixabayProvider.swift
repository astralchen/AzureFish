import Fluent
import Foundation
import SwiftProtobuf
import Vapor

/// 只接受 Pixabay 的 HTTPS 内容地址，拒绝凭据、端口及跨站重定向目标。
enum PixabayAddress {
    static func valid(_ text: String, media: Bool) -> Bool {
        guard let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil, let host = url.host?.lowercased() else { return false }
        return media ? host == "cdn.pixabay.com" : (host == "pixabay.com" || host == "www.pixabay.com")
    }
}
struct PixabayPage: Codable, Sendable {
    var videos: [Data]
    var hasMore: Bool
    var expires: Date
}
/// 上游只在用户翻页时访问；同一页合并请求，持久缓存 24 小时且响应不包含 Key。
actor PixabayProvider {
    typealias Fetch = @Sendable (URL) async throws -> (Data, Int)
    let key: String?
    let fetch: Fetch
    let clock: @Sendable () -> Date
    private var pending: [Int: Task<PixabayPage, Error>] = [:]
    private var retryAfter: Date = .distantPast
    init(key: String?, clock: @escaping @Sendable () -> Date = { Date() }, fetch: @escaping Fetch = PixabayProvider.fetch) {
        self.key = key; self.clock = clock; self.fetch = fetch
    }
    static func fetch(_ url: URL) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, response.url?.host == "pixabay.com" else {
            throw APIError(.badGateway, "SHORT_VIDEO_SOURCE_FAILED")
        }
        var data = Data()
        for try await byte in stream {
            guard data.count < 4 * 1024 * 1024 else { throw APIError(.badGateway, "SHORT_VIDEO_SOURCE_FAILED") }
            data.append(byte)
        }
        return (data, response.statusCode)
    }
    func page(_ page: Int, db: any Database, crypto: Cryptography) async throws -> PixabayPage {
        guard let key, !key.isEmpty else { throw APIError(.serviceUnavailable, "SHORT_VIDEO_SOURCE_UNCONFIGURED") }
        guard (1...25).contains(page) else { throw APIError(.badRequest, "INVALID_CURSOR") }
        if let task = pending[page] { return try await task.value }
        let cacheID = "page:\(page)"
        // 缓存读取也纳入合并任务，避免较晚返回的旧缓存快照触发第二次上游请求。
        let task = Task { [fetch, clock] in
            if let row = try await ShortVideoCacheRecord.find(cacheID, on: db) {
                let cached = try JSONDecoder().decode(PixabayPage.self, from: crypto.open(row.payload, context: "short-video:" + cacheID))
                if cached.expires > clock() { return cached }
            }
            guard clock() >= retryAfter else { throw APIError(.tooManyRequests, "SHORT_VIDEO_SOURCE_LIMITED") }
            var parts = URLComponents(string: "https://pixabay.com/api/videos/")!
            parts.queryItems = [URLQueryItem(name: "key", value: key), .init(name: "safesearch", value: "true"),
                .init(name: "order", value: "popular"), .init(name: "per_page", value: "20"), .init(name: "page", value: String(page))]
            let data: Data, status: Int
            do { (data, status) = try await fetch(parts.url!) }
            catch { throw APIError(.badGateway, "SHORT_VIDEO_SOURCE_FAILED") }
            guard status != 429 else { throw APIError(.tooManyRequests, "SHORT_VIDEO_SOURCE_LIMITED") }
            guard status == 200 else { throw APIError(.badGateway, "SHORT_VIDEO_SOURCE_FAILED") }
            let result: PixabayPage
            do { result = try Self.decode(data, page: page, now: clock()) }
            catch { throw APIError(.badGateway, "SHORT_VIDEO_SOURCE_FAILED") }
            let row = try await ShortVideoCacheRecord.find(cacheID, on: db) ?? ShortVideoCacheRecord()
            row.id = cacheID; row.payload = try crypto.seal(JSONEncoder().encode(result), context: "short-video:" + cacheID)
            try await row.save(on: db)
            return result
        }
        pending[page] = task
        defer { pending[page] = nil }
        do { return try await task.value }
        catch {
            if let error = error as? APIError, error.code == "SHORT_VIDEO_SOURCE_LIMITED" { retryAfter = clock().addingTimeInterval(60) }
            throw error
        }
    }
    private struct Response: Decodable { var totalHits: Int; var hits: [Hit] }
    private struct Hit: Decodable {
        var id: Int64; var pageURL: String; var tags: String; var duration: Int; var user: String
        var videos: [String: File]
    }
    private struct File: Decodable { var url: String; var width: Int; var height: Int; var size: Int64; var thumbnail: String? }
    static func decode(_ data: Data, page: Int, now: Date) throws -> PixabayPage {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var videos: [Data] = []
        for hit in response.hits.prefix(20) {
            guard hit.id > 0, (1...60).contains(hit.duration), PixabayAddress.valid(hit.pageURL, media: false) else { continue }
            var selected: File?
            for name in ["small", "tiny", "medium"] {
                guard let candidate = hit.videos[name], candidate.size > 0, candidate.size <= 50 * 1024 * 1024,
                      (1...8192).contains(candidate.width), (1...8192).contains(candidate.height),
                      PixabayAddress.valid(candidate.url, media: true), PixabayAddress.valid(candidate.thumbnail ?? "", media: true) else { continue }
                selected = candidate; break
            }
            guard let file = selected, let thumbnail = file.thumbnail else { continue }
            var video = ShortVideo(); video.videoID = "pixabay:\(hit.id)"; video.author = hit.user; video.tags = hit.tags
            video.sourceURL = hit.pageURL; video.videoURL = file.url; video.thumbnailURL = thumbnail
            video.byteCount = file.size; video.durationSeconds = Int32(hit.duration); video.width = Int32(file.width); video.height = Int32(file.height)
            videos.append(try video.serializedData())
        }
        return PixabayPage(videos: videos, hasMore: page * 20 < min(500, response.totalHits) && !response.hits.isEmpty, expires: now.addingTimeInterval(86400))
    }
}
