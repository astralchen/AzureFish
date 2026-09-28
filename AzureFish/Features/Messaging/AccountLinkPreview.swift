import Foundation
import UIKit

/// 真实账号使用无磁盘缓存的网页读取器；只解析公开元数据，不执行网页脚本。
@available(iOS 26.0, *)
@MainActor
enum AccountLinkPreview {
    static func load(_ link: LinkAttachment, files: any AttachmentStoring) async -> LinkAttachment {
        var result = link
        guard link.url.scheme?.lowercased() == "https", !Task.isCancelled else { return result }
        do {
            let data = try await read(link.url, limit: 1_048_576)
            guard let html = String(data: data, encoding: .utf8) else { return result }
            func capture(_ pattern: String, in text: String) -> String? {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[range]).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            }
            func meta(_ name: String) -> String? {
                let escaped = NSRegularExpression.escapedPattern(for: name)
                return capture("<meta\\b[^>]*(?:property|name)\\s*=\\s*[\"']" + escaped + "[\"'][^>]*content\\s*=\\s*[\"']([^\"']*)", in: html)
                    ?? capture("<meta\\b[^>]*content\\s*=\\s*[\"']([^\"']*)[\"'][^>]*(?:property|name)\\s*=\\s*[\"']" + escaped + "[\"']", in: html)
            }
            result.title = (meta("og:title") ?? capture("<title[^>]*>(.*?)</title>", in: html)).map { String($0.prefix(500)) }
            if let path = meta("og:image"), let url = URL(string: path, relativeTo: link.url)?.absoluteURL,
               url.scheme?.lowercased() == "https", !Task.isCancelled {
                let bytes = try await read(url, limit: 4_194_304)
                if let image = UIImage(data: bytes), image.size.width * image.size.height <= 16_000_000,
                   let png = image.pngData() {
                    let file = files.makeFileURL(prefix: "link-preview", pathExtension: "png")
                    try png.write(to: file, options: .atomic)
                    result.imageURL = file
                }
            }
        } catch { /* 元数据是可选展示；失败保留 URL。 */ }
        return result
    }
    @concurrent private static func read(_ url: URL, limit: Int) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.url?.scheme?.lowercased() == "https", response.expectedContentLength <= Int64(limit) else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}
