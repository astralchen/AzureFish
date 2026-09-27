import Foundation
import AzureFishAPI

/// 界面和加密快照共享的资料，不包含认证凭据。
struct AccountProfile: Codable, Equatable, Sendable {
    let userID: UUID
    let accountName: String
    var nickname: String
    var bio: String
    let version: Int64
    init(_ profile: UserProfile) {
        userID = profile.userID; accountName = profile.accountName
        nickname = profile.nickname; bio = profile.bio; version = profile.version
    }
    init(userID: UUID, accountName: String, nickname: String, bio: String, version: Int64) {
        self.userID = userID; self.accountName = accountName; self.nickname = nickname; self.bio = bio; self.version = version
    }
}

/// 表单校验遵循服务端契约；密码和用户资料不会在此规范化。
enum AccountValidation {
    static func account(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (3...32).contains(value.utf8.count) && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 95
        }
    }
    static func password(_ value: String) -> Bool {
        value.count >= 12 && value.utf8.count <= 72 && !value.contains("\0")
    }
    static func nickname(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 64 && text(value)
    }
    static func bio(_ value: String) -> Bool { value.count <= 500 && text(value) }
    private static func text(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }
    }
}

/// 以稳定资源键描述可恢复故障，避免将服务端正文或凭据暴露给界面。
enum AccountFailure: Error, Equatable {
    case busy, unavailable, storage, damagedCache, missingKey, expired, cancelled, offline, conflict, invalidInput
    var key: String {
        switch self {
        case .busy: "account.design.processing"
        case .unavailable: "account.unavailable"
        case .storage: "account.storage"
        case .damagedCache: "account.cache.damaged"
        case .missingKey: "account.cache.key"
        case .expired: "account.expired"
        case .cancelled: "account.cancelled"
        case .offline: "account.offline"
        case .conflict: "account.conflict"
        case .invalidInput: "account.validation"
        }
    }
    static func key(for error: Error) -> String {
        if let failure = error as? Self { return failure.key }
        if error is CancellationError { return Self.cancelled.key }
        if let api = error as? APIClientError {
            switch api {
            case .network: return Self.offline.key
            case .service(let failure):
                switch failure.code {
                case .invalidCredentials: return "account.credentials.invalid"
                case .accountTaken: return "account.taken"
                case .profileVersionConflict: return Self.conflict.key
                case .unauthenticated, .refreshReplay, .refreshSuperseded: return Self.expired.key
                case .validationFailed: return Self.invalidInput.key
                case .authAttemptExpired, .operationResultExpired: return "account.operation.expired"
                case .rateLimited: return "account.rate.limit"
                default: return "account.error"
                }
            default: return "account.error"
            }
        }
        return "account.error"
    }
}
