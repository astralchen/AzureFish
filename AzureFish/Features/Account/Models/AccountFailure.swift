import Foundation
import AzureFishAPI

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
        if let error = error as? APISessionError, error == .verificationRequired { return "account.connection.checking" }
        if error is CancellationError { return Self.cancelled.key }
        if let api = error as? APIClientError {
            switch api {
            case .network: return Self.offline.key
            case .service(let failure):
                switch failure.code {
                case .reauthRequired: return "account.security.reauthenticate"
                case .ownerTransferRequired: return "account.security.ownedGroups"
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
