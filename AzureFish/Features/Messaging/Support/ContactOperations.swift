import AzureFishAPI
import AzureFishChat
import Foundation

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
        let saved: PendingContactOperation? = try await engine.store.pendingContactOperation(peer: peer)
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
                revision: fresh.revision, remark: remark, message: message,
                requestID: [.accept, .reject, .cancel].contains(action) ? fresh.requestID : ""),
                action: action, remark: remark, message: message)
            try await engine.store.saveContactOperation(pending, peer: peer)
        }
        guard runtime.engine === engine else { throw CancellationError() }
        do {
            // 即使页面退出，已发出请求仍对账并落库；旧账号结果不能发布到当前界面。
            let result = try await api.mutateContact(bytes: pending.bytes)
            try await engine.store.save(result)
            try await engine.store.removeContactOperation(peer: peer)
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
                try await engine.store.removeContactOperation(peer: peer)
                runtime.receivedContact(fresh, engine: engine)
                if failure.code == .operationResultExpired { throw ContactOperationError.resultExpired }
            }
            throw error
        }
    }
}
