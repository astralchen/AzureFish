import AzureFishAPI
import AzureFishChat
import AzureFishNetwork
import AzureFishProtocol
import Foundation
import SwiftProtobuf
import Testing
import UIKit
@testable import AzureFish

private actor ContactTestTransport: HTTPTransport {
    let account = AccountTestTransport()
    var contact: ContactRelationship
    var writes: [Data] = []
    var results: [String: ContactRelationship] = [:]
    var drop = true
    var lookupStarted = false
    init() {
        var value = ContactRelationship(); value.peer.userID = "00000000-0000-0000-0000-000000000012"
        value.peer.nickname = "Fixture"; value.relationshipID = "fixture"; value.revision = 2
        value.semanticsVersion = 2; value.isContact = true; value.state = "friend"
        value.availableActions = ["remark", "send", "delete", "block"]; contact = value
    }
    func setDrop(_ value: Bool) { drop = value }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.hasSuffix("users/lookup") {
            lookupStarted = true
            // 模拟取消后仍到达的旧网络响应。
            try? await Task.sleep(nanoseconds: 200_000_000)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try contact.peer.serializedData())
        }
        if request.url.path.hasSuffix("contacts/get") {
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try contact.serializedData())
        }
        if request.url.path.hasSuffix("contacts/mutate") {
            let bytes = try #require(request.body); writes.append(bytes)
            let input = try ContactMutationRequest(serializedBytes: bytes)
            if results[input.operationID] == nil {
                contact.remark = input.remark; contact.revision += 1; results[input.operationID] = contact
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            if drop { throw URLError(.networkConnectionLost) }
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try contact.serializedData())
        }
        if request.url.path.contains("/im/") { throw URLError(.notConnectedToInternet) }
        return try await account.send(request)
    }
}

@MainActor
struct ChatContactOperationsTests {
    @Test func responseLossRestoresOriginalBytesAndDuplicateTapDoesNotCreateOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ContactTestTransport(), keys = MemorySecureValues()
        let credentials = try sampleCredentials()
        let credentialStore = CredentialStore(values: keys, environmentID: credentials.environmentID)
        try credentialStore.save(StoredSession(credentials))
        let session = SessionCoordinator(service: LiveAccountService(api: AccountAPI(environment: try .localTesting(), transport: transport)),
            store: credentialStore, repository: UserRepository(root: root.appendingPathComponent("profile"), keys: keys, environment: credentials.environmentID))
        await session.restore()
        let database = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 7, count: 32), environment: credentials.environmentID, userID: credentials.userID)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 8, count: 32), environment: credentials.environmentID, userID: credentials.userID)
        let engine = ChatEngine(store: database, session: try #require(session.sessionManager))
        let contact = await ChatContact(transport.contact)
        let runtime = ChatRuntime(session: session, engine: engine, media: media, conversations: [], pageLeaseRoot: root, contacts: [contact])
        let operation = Task { try await runtime.contactOperations.mutate(contact, action: .remark, remark: "私人备注") }
        while await transport.writes.isEmpty { await Task.yield() }
        await #expect(throws: ContactOperationError.self) {
            try await runtime.contactOperations.mutate(contact, action: .delete)
        }
        await #expect(throws: (any Error).self) { try await operation.value }
        let key = "contact.operation." + contact.peer.id
        let pending: PendingContactOperation? = try await database.meta(key)
        #expect(pending != nil)
        #expect(runtime.contacts.first?.remark == "")
        await transport.setDrop(false)
        // 新实例模拟页面重建，操作身份仍从账号加密库恢复。
        let restored = try await ContactOperations(runtime: runtime).mutate(contact, action: .remark, remark: "私人备注")
        #expect(restored.remark == "私人备注" && restored.revision == 3)
        let writes = await transport.writes
        #expect(writes.count >= 2 && Set(writes).count == 1)
        let cleared: PendingContactOperation? = try await database.meta(key)
        #expect(cleared == nil)
        _ = try await runtime.contactOperations.mutate(restored, action: .remark, remark: "新备注")
        #expect(await transport.contact.revision == 4)
        let add = AddFriendViewController(runtime: runtime)
        let navigation = UINavigationController(rootViewController: add)
        navigation.loadViewIfNeeded(); add.loadViewIfNeeded()
        let field = try #require(add.fields.compactMap { $0 as? AccountField }.first)
        field.input.text = "old_account"
        add.controls.first?.sendActions(for: .touchUpInside)
        while await !transport.lookupStarted { await Task.yield() }
        field.input.text = "new_account"; field.input.sendActions(for: .editingChanged)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(navigation.topViewController === add && field.input.text == "new_account")
        #expect(!add.busy)
        runtime.stop()
    }
}
