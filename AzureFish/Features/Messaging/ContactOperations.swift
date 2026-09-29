import AzureFishAPI
import AzureFishChat
import Foundation

struct PendingContactOperation: Codable, Sendable {
    let bytes: Data
    let action: ContactAction
    let remark: String
    let message: String
}
enum ContactOperationError: Error { case busy, unavailable, confirmedPrevious, resultExpired }

/// 将不确定的联系人写请求保存在当前账号加密库；重试先恢复原字节，不创建替代操作。
@MainActor
final class ContactOperations {
    private unowned let runtime: ChatRuntime
    private static var busyScopes = Set<String>()
    init(runtime: ChatRuntime) { self.runtime = runtime }
    func mutate(_ contact: ChatContact, action: ContactAction, remark: String = "", message: String = "") async throws -> ChatContact {
        guard let engine = runtime.engine, let api = runtime.api, contact.semanticsVersion == 2 else {
            throw ContactOperationError.unavailable
        }
        let peer = contact.peer.id
        let scope = engine.store.environment + ":" + engine.store.userID.uuidString + ":" + peer
        guard !Self.busyScopes.contains(scope) else { throw ContactOperationError.busy }
        Self.busyScopes.insert(scope)
        defer { Self.busyScopes.remove(scope) }
        let key = "contact.operation." + peer
        let saved: PendingContactOperation? = try await engine.store.meta(key)
        try Task.checkCancellation()
        guard runtime.engine === engine else { throw CancellationError() }
        let pending: PendingContactOperation
        if let saved { pending = saved }
        else {
            let fresh = try await api.contact(peer: peer)
            try Task.checkCancellation()
            guard runtime.engine === engine else { throw CancellationError() }
            guard fresh.semanticsVersion == 2 else { throw ContactOperationError.unavailable }
            guard fresh.revision == contact.revision else {
                try await engine.store.save(fresh)
                runtime.receivedContact(fresh, engine: engine)
                throw ContactOperationError.resultExpired
            }
            guard fresh.allows(action) else { throw ContactOperationError.unavailable }
            pending = PendingContactOperation(bytes: try IMAPI.contactMutation(peer: peer, action: action,
                revision: fresh.revision, operationID: UUID(), remark: remark, message: message,
                requestID: [.accept, .reject, .cancel].contains(action) ? fresh.requestID : ""),
                action: action, remark: remark, message: message)
            try await engine.store.setMeta(pending, id: key)
        }
        guard runtime.engine === engine else { throw CancellationError() }
        do {
            // 即使页面退出，已发出请求仍对账并落库；旧账号结果不能发布到当前界面。
            let result = try await api.mutateContact(bytes: pending.bytes)
            try await engine.store.save(result)
            try await engine.store.removeMeta(key)
            guard runtime.engine === engine else { throw CancellationError() }
            runtime.receivedContact(result, engine: engine)
            runtime.changed(); runtime.refresh()
            if saved != nil && (pending.action != action || pending.remark != remark || pending.message != message) {
                throw ContactOperationError.confirmedPrevious
            }
            return runtime.contacts.first { $0.peer.id == peer } ?? result
        } catch {
            if case APIClientError.service(let failure) = error, (400..<500).contains(failure.statusCode), failure.statusCode != 429 {
                let fresh = try await api.contact(peer: peer)
                try await engine.store.save(fresh)
                try await engine.store.removeMeta(key)
                runtime.receivedContact(fresh, engine: engine)
                if failure.code == .operationResultExpired { throw ContactOperationError.resultExpired }
            }
            throw error
        }
    }
}

@MainActor
func contactErrorKey(_ error: any Error) -> String {
    if let error = error as? ContactOperationError {
        switch error {
        case .confirmedPrevious, .resultExpired: return "contacts.reconciled"
        case .busy: return "contacts.busy"
        case .unavailable: return "contacts.unavailable"
        }
    }
    if case APIClientError.service(let failure) = error {
        switch failure.code {
        case .selfContact: return "chat.live.selfContact"
        case .userNotFound: return "contacts.notFound"
        case .rateLimited: return "contacts.rateLimited"
        case .contactClientUpdateRequired: return "contacts.updateRequired"
        case .contactVersionConflict, .contactActionUnavailable: return "chat.live.changed"
        case .contactUnavailable: return "contacts.unavailable"
        case .validationFailed: return "contacts.invalidInput"
        default: return "chat.live.failed"
        }
    }
    return "contacts.networkError"
}
