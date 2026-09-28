#if os(macOS) && DEBUG
    import AzureFishAPI
    import CryptoKit
    import Foundation
    import Testing
    @testable import AzureFishChat

    private actor ChatTestSessionStore: APISessionStore {
        private var value: APISessionRecord?
        func load(environmentID: String) -> APISessionRecord? { value }
        func save(_ record: APISessionRecord, environmentID: String) { value = record }
        func clear(environmentID: String) { value = nil }
    }

    @Suite("真实好友与客户端加密发送", .timeLimit(.minutes(2)))
    struct IndependentChatTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["AZUREFISH_CHAT_TEST_PORT"] != nil))
        func friendMessageMediaAndRevocation() async throws {
            let port = try #require(
                Int(ProcessInfo.processInfo.environment["AZUREFISH_CHAT_TEST_PORT"] ?? ""))
            guard port != 8080 else { throw ChatStoreError.scopeMismatch }
            let api = AccountAPI(environment: try .localTesting(port: port))
            func user() async throws -> APISessionManager {
                let registration = try api.prepareRegistration(
                    operationID: UUID(), deviceID: UUID(),
                    accountName: "chat_" + UUID().uuidString.prefix(8).lowercased(),
                    password: "Fictional-Password-123", nickname: "虚构聊天用户")
                let auth = try await api.execute(registration)
                let manager = APISessionManager(api: api, store: ChatTestSessionStore())
                try await manager.install(auth.credentials)
                return manager
            }
            let a = try await user()
            let b = try await user()
            let aID = try await a.localIdentity().userID
            let bID = try await b.localIdentity().userID
            let first = IMAPI(session: a)
            let second = IMAPI(session: b)
            await #expect(throws: (any Error).self) {
                try await first.resolve(peer: bID.uuidString, operationID: UUID())
            }
            let bProfile = try await b.authorized { try await api.profile(using: $0) }
            #expect(try await first.lookup(account: bProfile.accountName).id == bID.uuidString.lowercased())
            let requestBytes = try IMAPI.contactMutation(peer: bID.uuidString, action: .request, revision: 0, operationID: UUID(), message: "见面认识的朋友")
            let request = try await first.mutateContact(bytes: requestBytes)
            #expect(try await first.mutateContact(bytes: requestBytes).requestID == request.requestID)
            #expect(request.requestMessage == "见面认识的朋友")
            _ = try await second.mutateContact(
                peer: aID.uuidString, action: .accept, revision: request.revision,
                operationID: UUID(), requestID: request.requestID)
            let conversation = try await first.resolve(peer: bID.uuidString, operationID: UUID())
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let store = try ChatStore(
                url: root.appendingPathComponent("account.sqlite"), key: key,
                environment: api.environment.identifier, userID: aID)
            let media = try ChatMediaStore(
                root: root.appendingPathComponent("media"), key: key,
                environment: api.environment.identifier, userID: aID)
            let engine = ChatEngine(store: store, session: a)
            let queue = ChatTransferQueue(store: store, media: media, session: a, engine: engine)
            do {
                try await engine.synchronize()
                #expect(
                    try await store.contacts().contains {
                        $0.state == "friend" && $0.peer.id == bID.uuidString.lowercased()
                    })
                let relationship = try await first.contact(peer: bID.uuidString)
                _ = try await first.mutateContact(peer: bID.uuidString, action: .remark, revision: relationship.revision, operationID: UUID(), remark: "我的同事")
                _ = try await b.authorized { credentials in
                    let operation = try api.prepareProfileUpdate(operationID: UUID(), changes: .init(expectedVersion: bProfile.version, nickname: "新的公开昵称"), using: credentials)
                    return try await api.execute(operation, using: credentials)
                }
                try await engine.synchronize()
                let updated = try #require(try await store.contacts().first { $0.peer.id == bID.uuidString.lowercased() })
                #expect(updated.displayName == "我的同事" && updated.peer.nickname == "新的公开昵称")
                #expect(try await second.contact(peer: aID.uuidString).remark.isEmpty)
                try await store.setConversationPreferences(.init(isPinned: true, isMuted: true), conversation: conversation.id)
                #expect(try await store.conversationPreferences(conversation.id).isPinned)
                var incoming = await engine.incomingMessages().makeAsyncIterator()
                await engine.setForegroundNotificationsEnabled(true)
                let bDevice = try await b.localIdentity().deviceID
                _ = try await second.send(.init(conversationID: conversation.id, deviceID: bDevice, text: "前台基线"))
                try await engine.synchronize()
                let alertMessage = try await second.send(.init(conversationID: conversation.id, deviceID: bDevice, text: "新的前台消息"))
                try await engine.synchronize()
                #expect(await incoming.next()?.map(\.id) == [alertMessage.id])
                #expect(try await store.searchMessages(conversation: conversation.id, query: "前台消息").messages.map(\.id) == [alertMessage.id])
                try await engine.send(conversation: conversation.id, text: "真实 HTTP 与加密 outbox")
                #expect(try await store.pending().isEmpty)
                let history = try await second.history(conversation.id)
                let original = try #require(history.messages.first { $0.text == "真实 HTTP 与加密 outbox" })
                let revoked = try await engine.revoke(original, fallbackOperationID: UUID())
                #expect(revoked.message.revoked && revoked.canReedit)
                #expect(try await store.searchMessages(conversation: conversation.id, query: "outbox").messages.isEmpty)
                try await store.saveDraft(
                    .init(text: "Existing draft", assets: ["draft-attachment"]),
                    conversation: conversation.id)
                let restored = try await store.restoreReeditedDraft(
                    message: original.id, conversation: conversation.id,
                    expectedText: "Existing draft")
                #expect(restored.text == original.text && restored.assets == ["draft-attachment"])
                try await engine.send(
                    conversation: conversation.id, text: restored.text + " · edited")
                let editedHistory = try await second.history(conversation.id)
                #expect(editedHistory.messages.first { $0.id == original.id }?.revoked == true)
                let noRecovery = try #require(editedHistory.messages.first { $0.id != original.id && $0.text == original.text + " · edited" })
                #expect(noRecovery.sequence > original.sequence)
                #expect(try await store.pending().isEmpty)
                let failedStore = try ChatStore(
                    url: root.appendingPathComponent("closed.sqlite"), key: key,
                    environment: api.environment.identifier, userID: aID)
                try await failedStore.close()
                let unavailableEngine = ChatEngine(store: failedStore, session: a)
                let successfulRevoke = try await unavailableEngine.revoke(
                    noRecovery, fallbackOperationID: UUID())
                #expect(successfulRevoke.message.revoked && !successfulRevoke.canReedit)
                #expect(
                    try await second.history(conversation.id).messages.first {
                        $0.id == noRecovery.id
                    }?.revoked == true)
                let source = root.appendingPathComponent("source.bin")
                let data = Data(repeating: 0x71, count: ChatMediaStore.chunkBytes + 37)
                try data.write(to: source)
                let local = try await media.importFile(
                    source, filename: "fixture.bin", mime: "application/octet-stream")
                let credentials = try await a.localIdentity()
                let batch = ChatUploadBatch(
                    conversation: conversation.id, kind: "file",
                    items: [.init(kind: "file", resources: [local])], deviceID: credentials.deviceID
                )
                let rich = ChatOutgoing(conversationID: conversation.id, deviceID: credentials.deviceID,
                    text: "真实格式 👩🏽‍💻", textRuns: [.init(text: "真实格式 👩🏽‍💻", style: 9)])
                let link = ChatOutgoing(conversationID: conversation.id, deviceID: credentials.deviceID, kind: "link",
                    text: "https://example.com/fixture", linkURL: "https://example.com/fixture")
                try await store.enqueueComposition([.upload(batch), .message(rich), .message(link)], conversation: conversation.id)
                await engine.flush()
                #expect(try await store.pending().count == 2)
                await queue.resume()
                for _ in 0..<200 {
                    if try await store.transfers(as: ChatUploadBatch.self).isEmpty, try await store.pending().isEmpty { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                #expect(try await store.transfers(as: ChatUploadBatch.self).isEmpty)
                let sent = try #require(
                    try await first.history(conversation.id).messages.first { $0.kind == "file" })
                let received = try await second.history(conversation.id)
                let receivedRich = try #require(received.messages.first { $0.id == rich.id.uuidString.lowercased() })
                let receivedLink = try #require(received.messages.first { $0.id == link.id.uuidString.lowercased() })
                #expect(sent.sequence < receivedRich.sequence && receivedRich.sequence < receivedLink.sequence)
                #expect(receivedRich.textRuns == rich.textRuns && receivedLink.linkURL == link.linkURL)
                let resource = try #require(
                    sent.assets.first?.resources.first { $0.role == "original" })
                let cached = try await queue.download(resource, message: sent.id)
                let lease = try await media.lease(cached)
                #expect(try Data(contentsOf: lease) == data)
                try await media.release(lease)
                try await store.saveDraft(.init(text: "关系变更保留草稿"), conversation: conversation.id)
                _ = try await first.mutateContact(
                    peer: bID.uuidString, action: .delete, revision: first.contact(peer: bID.uuidString).revision,
                    operationID: UUID())
                _ = try await queue.download(resource, message: sent.id)
                _ = try await first.revoke(
                    conversation: conversation.id, message: sent.id, operationID: UUID())
                await #expect(throws: (any Error).self) {
                    _ = try await queue.download(resource, message: sent.id)
                }
                let deleted = try await first.contact(peer: bID.uuidString)
                #expect(!deleted.isContact && deleted.remark == "我的同事")
                #expect(try await second.contact(peer: aID.uuidString).isContact)
                await #expect(throws: (any Error).self) { try await second.send(.init(conversationID: conversation.id, deviceID: bDevice, text: "暂停联系")) }
                let restoredContact = try await first.mutateContact(peer: bID.uuidString, action: .restore, revision: deleted.revision, operationID: UUID())
                #expect(restoredContact.canSend)
                let blocked = try await first.mutateContact(peer: bID.uuidString, action: .block, revision: restoredContact.revision, operationID: UUID())
                #expect(blocked.isBlocked && !blocked.canSend)
                let unblocked = try await first.mutateContact(peer: bID.uuidString, action: .unblock, revision: blocked.revision, operationID: UUID())
                #expect(unblocked.canSend && unblocked.remark == "我的同事")
                try await engine.synchronize()
                #expect(try await store.draft(conversation.id).text == "关系变更保留草稿")
                await queue.stop()
                await engine.stop()
                try await store.close()
            } catch {
                await queue.stop()
                await engine.stop()
                try? await store.close()
                throw error
            }
            if let path = ProcessInfo.processInfo.environment["AZUREFISH_CHAT_TEST_COMPLETION"] {
                try Data("completed".utf8).write(to: URL(fileURLWithPath: path))
            }
        }
    }
#endif
