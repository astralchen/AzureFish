import Foundation
import SwiftProtobuf
import Vapor

struct APIError: Error, Sendable {
    let status: HTTPResponseStatus
    let code: String
    let field: String
    init(_ status: HTTPResponseStatus, _ code: String, field: String = "") {
        self.status = status; self.code = code; self.field = field
    }
}

func protobufResponse<M: Message>(_ message: M, status: HTTPResponseStatus = .ok) throws -> Response {
    Response(status: status, headers: ["Content-Type": "application/protobuf", "Cache-Control": "no-store"], body: .init(data: try message.serializedData()))
}

func requestMessage<M: Message>(_ type: M.Type, from req: Request) throws -> (M, Data) {
    guard req.headers.contentType == HTTPMediaType(type: "application", subType: "protobuf") else {
        throw APIError(.unsupportedMediaType, "UNSUPPORTED_MEDIA_TYPE")
    }
    guard let buffer = req.body.data else { throw APIError(.badRequest, "MALFORMED_PROTOBUF") }
    let data = Data(buffer.readableBytesView)
    do { return (try M(serializedBytes: data), data) }
    catch { throw APIError(.badRequest, "MALFORMED_PROTOBUF") }
}

struct APIMiddleware: AsyncMiddleware {
    let limiter: RateLimiter
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let requestID = UUID().uuidString.lowercased()
        let response: Response
        do {
            try await limiter.check("ip:" + (request.remoteAddress?.ipAddress ?? "local"), limit: 120)
            if let size = request.body.data?.readableBytes, size > 16 * 1024 {
                throw APIError(.payloadTooLarge, "PAYLOAD_TOO_LARGE")
            }
            if let accept = request.headers.first(name: .accept),
               !accept.split(separator: ",").contains(where: {
                   let media = ($0.split(separator: ";", omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespaces)
                   return media == "application/protobuf" || media == "*/*" || media == "application/*"
               }) {
                throw APIError(.notAcceptable, "NOT_ACCEPTABLE")
            }
            response = try await next.respond(to: request)
        } catch {
            let mapped: APIError
            if let error = error as? APIError { mapped = error }
            else if let abort = error as? any AbortError {
                mapped = APIError(abort.status, abort.status == .payloadTooLarge ? "PAYLOAD_TOO_LARGE" : "HTTP_ERROR")
            } else {
                mapped = APIError(.internalServerError, "INTERNAL_ERROR")
                // 不输出底层异常，数据库／解码异常可能包含绑定参数或请求正文。
                request.logger.error("Request failed", metadata: ["request_id": .string(requestID), "code": "INTERNAL_ERROR"])
            }
            var message = Azurefish_V1_ApiError()
            message.code = mapped.code; message.field = mapped.field; message.requestID = requestID
            response = try protobufResponse(message, status: mapped.status)
            if mapped.status == .tooManyRequests { response.headers.replaceOrAdd(name: "Retry-After", value: "60") }
        }
        response.headers.replaceOrAdd(name: "X-Request-ID", value: requestID)
        response.headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return response
    }
}

enum Validation {
    static func uuid(_ value: String, field: String) throws -> UUID {
        guard value.count == 36, let id = UUID(uuidString: value) else { throw APIError(.badRequest, "VALIDATION_FAILED", field: field) }
        return id
    }
    static func account(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.allSatisfy({ $0 < 128 }) else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "account_name") }
        let normalized = trimmed.lowercased()
        guard normalized.utf8.count >= 3, normalized.utf8.count <= 32,
              normalized.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
            throw APIError(.badRequest, "VALIDATION_FAILED", field: "account_name")
        }
        return normalized
    }
    static func password(_ value: String) throws {
        guard value.count >= 12, value.utf8.count <= 72, !value.utf8.contains(0) else {
            throw APIError(.badRequest, "VALIDATION_FAILED", field: "password")
        }
    }
    static func text(_ value: String, field: String, max: Int, allowEmpty: Bool = false) throws {
        guard value.count <= max, allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }) else {
            throw APIError(.badRequest, "VALIDATION_FAILED", field: field)
        }
    }
}
