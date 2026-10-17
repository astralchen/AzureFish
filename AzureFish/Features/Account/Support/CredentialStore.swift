import Foundation
import AzureFishAPI

@MainActor
final class CredentialStore {
    let values: any SecureValueStoring
    let environmentID: String
    private var sessionKey: String { "session.\(environmentID)" }
    private var revocationKey: String { "revocations.\(environmentID)" }
    init(values: any SecureValueStoring, environmentID: String) {
        self.values = values; self.environmentID = environmentID
    }
    func installationID() throws -> UUID {
        if let data = try values.read("installation"), let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value) { return id }
        if try values.read("installation") != nil { throw AccountFailure.storage }
        let id = UUID()
        try values.write(Data(id.uuidString.utf8), key: "installation")
        return id
    }
    func load() throws -> StoredSession? {
        guard let data = try values.read(sessionKey) else { return nil }
        guard let stored = try? JSONDecoder().decode(StoredSession.self, from: data),
              stored.environmentID == environmentID, (try? stored.credentials()) != nil else { throw AccountFailure.storage }
        return stored
    }
    func save(_ value: StoredSession) throws {
        guard value.environmentID == environmentID else { throw AccountFailure.storage }
        try values.write(JSONEncoder().encode(value), key: sessionKey)
    }
    func clear() throws { try values.remove(sessionKey) }
    private var rememberedKey: String { "remembered-login." + environmentID }
    func rememberedAccount() throws -> RememberedLoginAccount? {
        guard let data = try values.read(rememberedKey) else { return nil }
        let value = try JSONDecoder().decode(RememberedLoginAccount.self, from: data)
        guard value.environmentID == environmentID else { throw AccountFailure.storage }
        return value
    }
    func remember(_ profile: AccountProfile) throws {
        let value = RememberedLoginAccount(environmentID: environmentID, userID: profile.userID, accountName: profile.accountName)
        try values.write(JSONEncoder().encode(value), key: rememberedKey)
    }
    func forgetAccount(user: UUID) throws {
        if try rememberedAccount()?.userID == user { try values.remove(rememberedKey) }
    }
    func revocations() throws -> [LogoutRevocation] {
        guard let data = try values.read(revocationKey) else { return [] }
        do { return try JSONDecoder().decode([LogoutRevocation].self, from: data) }
        catch { throw AccountFailure.storage }
    }
    func saveRevocations(_ values: [LogoutRevocation]) throws {
        if values.isEmpty { try self.values.remove(revocationKey) }
        else { try self.values.write(JSONEncoder().encode(values), key: revocationKey) }
    }
}
