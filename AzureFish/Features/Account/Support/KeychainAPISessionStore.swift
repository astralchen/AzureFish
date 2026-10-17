import AzureFishAPI

/// 适配已有原子 Keychain 会话包，HTTP 与实时连接共用同一份凭据。
@MainActor
final class KeychainAPISessionStore: APISessionStore {
    private let store: CredentialStore
    init(store: CredentialStore) { self.store = store }
    func load(environmentID: String) async throws -> APISessionRecord? {
        guard environmentID == store.environmentID else { throw AccountFailure.storage }
        return try store.load().map { try APISessionRecord(credentials: $0.credentials(), pendingRefreshOperationID: $0.pendingRefreshID) }
    }
    func save(_ record: APISessionRecord, environmentID: String) async throws {
        guard environmentID == store.environmentID else { throw AccountFailure.storage }
        try store.save(StoredSession(record.credentials, pendingRefreshID: record.pendingRefreshOperationID))
    }
    func clear(environmentID: String) async throws {
        guard environmentID == store.environmentID else { throw AccountFailure.storage }
        try store.clear()
    }
}
