import AzureFishAPI
import Foundation
import Testing

@testable import AzureFishChat

private final class ReeditClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date.addTimeInterval(seconds)
    }
}

@Suite("撤回文本恢复")
struct ChatReeditTests {
    private func message(user: UUID, kind: String = "text") throws -> ChatMessage {
        let json: [String: Any] = [
            "id": UUID().uuidString.lowercased(), "conversationID": UUID().uuidString.lowercased(),
            "clientID": UUID().uuidString, "serverID": UUID().uuidString,
            "senderID": user.uuidString.lowercased(),
            "deviceID": UUID().uuidString, "sequence": 1, "createdAt": 1_800_000_000_000,
            "revision": 1,
            "kind": kind, "schemaVersion": 1, "text": "Original secret 原文 العربية",
            "revoked": false,
            "receipt": ["expected": 1, "delivered": 1, "read": 0, "revision": 1], "assets": [],
        ]
        return try JSONDecoder().decode(
            ChatMessage.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func revoked(_ message: ChatMessage) -> ChatMessage {
        var value = message
        value.revoked = true
        value.text = ""
        value.revision += 1
        return value
    }
    private func fixture(_ run: (ChatStore, ReeditClock, UUID, URL, Data) async throws -> Void)
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ReeditClock()
        let user = UUID()
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let url = root.appendingPathComponent("chat.sqlite")
        let store = try ChatStore(
            url: url, key: key, environment: "test", userID: user, now: { clock.now })
        do {
            try await run(store, clock, user, url, key)
            try? await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
    @Test func formattingSurvivesReeditAndExpiresWithText() async throws {
        try await fixture { store, clock, user, _, _ in
            var original = try message(user: user)
            original.textRuns = [.init(text: original.text, style: 15)]
            try await store.save(original)
            _ = try await store.prepareRevoke(original, operationID: UUID())
            try await store.save(revoked(original))
            #expect(try await store.reeditRuns(message: original.id, conversation: original.conversationID) == original.textRuns)
            let saved = try #require(await store.messages(original.conversationID).first)
            #expect(saved.textRuns == nil && saved.linkURL == nil)
            clock.advance(181)
            await #expect(throws: ChatStoreError.reeditExpired) {
                try await store.reeditRuns(message: original.id, conversation: original.conversationID)
            }
        }
    }
    @Test func confirmationStartsOneWindowAndReopenDoesNotExtendIt() async throws {
        try await fixture { store, clock, user, url, key in
            let original = try message(user: user)
            let operation = UUID()
            try await store.save(original)
            let attempt = try await store.prepareRevoke(original, operationID: operation)
            #expect(attempt.operationID == operation && attempt.recoveryStored)
            #expect(
                try await store.reeditAvailability(conversation: original.conversationID).isEmpty)
            clock.advance(20)
            try await store.save(revoked(original))
            let deadline = try #require(
                await store.reeditAvailability(conversation: original.conversationID).first?
                    .expiresAt)
            #expect(deadline == clock.now.addingTimeInterval(180))
            clock.advance(60)
            try await store.save(revoked(original))
            try await store.rejectRevoke(message: original.id)
            #expect(
                try await store.prepareRevoke(original, operationID: UUID()).operationID
                    == operation)
            try await store.close()
            #expect(
                !String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(original.text))
            let reopened = try ChatStore(
                url: url, key: key, environment: "test", userID: user, now: { clock.now })
            #expect(
                try await reopened.reeditAvailability(conversation: original.conversationID).first?
                    .expiresAt == deadline)
            #expect(try await reopened.messages(original.conversationID).first?.text == "")
            clock.advance(120)
            await #expect(throws: ChatStoreError.reeditExpired) {
                try await reopened.reeditText(
                    message: original.id, conversation: original.conversationID)
            }
            try await reopened.save(original)
            try await reopened.save(revoked(original))
            #expect(
                try await reopened.reeditAvailability(conversation: original.conversationID).isEmpty
            )
            #expect(try await reopened.messages(original.conversationID).first?.revoked == true)
            try await reopened.close()
        }
    }
    @Test func replacementChecksDraftAndPreservesAttachmentsAndNewIdentity() async throws {
        try await fixture { store, clock, user, _, _ in
            let original = try message(user: user)
            try await store.save(original)
            _ = try await store.prepareRevoke(original, operationID: UUID())
            try await store.save(revoked(original))
            try await store.saveDraft(
                .init(text: "Existing", assets: ["a", "b"]), conversation: original.conversationID)
            await #expect(throws: ChatStoreError.draftChanged) {
                try await store.restoreReeditedDraft(
                    message: original.id, conversation: original.conversationID,
                    expectedText: "Stale")
            }
            #expect(try await store.draft(original.conversationID).text == "Existing")
            let draft = try await store.restoreReeditedDraft(
                message: original.id, conversation: original.conversationID,
                expectedText: "Existing")
            #expect(draft.text == original.text && draft.assets == ["a", "b"])
            clock.advance(180)
            await #expect(throws: ChatStoreError.reeditExpired) {
                try await store.restoreReeditedDraft(
                    message: original.id, conversation: original.conversationID,
                    expectedText: original.text)
            }
            #expect(try await store.draft(original.conversationID).text == original.text)
            let outgoing = ChatOutgoing(
                conversationID: original.conversationID, deviceID: UUID(), text: draft.text)
            try await store.enqueue(outgoing)
            #expect(outgoing.id.uuidString.lowercased() != original.id)
            #expect(try await store.messages(original.conversationID).first?.revoked == true)
        }
    }
    @Test func pendingExpiryAndFailureCannotBeResurrected() async throws {
        try await fixture { store, clock, user, _, _ in
            let original = try message(user: user)
            let operation = UUID()
            try await store.save(original)
            _ = try await store.prepareRevoke(original, operationID: operation)
            clock.advance(180)
            #expect(
                try await store.prepareRevoke(original, operationID: UUID()).operationID
                    == operation)
            try await store.save(revoked(original))
            #expect(
                try await store.reeditAvailability(conversation: original.conversationID).isEmpty)
            let failed = try message(user: user)
            try await store.save(failed)
            _ = try await store.prepareRevoke(failed, operationID: UUID())
            try await store.rejectRevoke(message: failed.id)
            try await store.save(revoked(failed))
            #expect(try await store.reeditAvailability(conversation: failed.conversationID).isEmpty)
        }
    }
    @Test func foreignMediaAndNonInitiatingDeviceNeverRecover() async throws {
        try await fixture { store, _, user, _, _ in
            let foreign = try message(user: UUID())
            try await store.save(foreign)
            await #expect(throws: ChatStoreError.scopeMismatch) {
                try await store.prepareRevoke(foreign, operationID: UUID())
            }
            try await store.save(revoked(foreign))
            let media = try message(user: user, kind: "file")
            try await store.save(media)
            #expect(
                try await store.prepareRevoke(media, operationID: UUID()).recoveryStored == false)
            try await store.save(revoked(media))
            #expect(try await store.reeditAvailability(conversation: media.conversationID).isEmpty)
            let otherDevice = try message(user: user)
            try await store.save(otherDevice)
            try await store.save(revoked(otherDevice))
            #expect(
                try await store.reeditAvailability(conversation: otherDevice.conversationID).isEmpty
            )
        }
    }
    @Test func localDeletionAndClearEraseRecovery() async throws {
        try await fixture { store, _, user, _, _ in
            for clear in [false, true] {
                let original = try message(user: user)
                try await store.save(original)
                _ = try await store.prepareRevoke(original, operationID: UUID())
                try await store.save(revoked(original))
                if clear {
                    try await store.clear(conversation: original.conversationID)
                } else {
                    try await store.hide(message: original.id)
                }
                try await store.save(revoked(original))
                #expect(
                    try await store.reeditAvailability(conversation: original.conversationID)
                        .isEmpty)
            }
        }
    }
    @Test func syncBeforeResponseCommitsRecoveryWithCheckpoint() async throws {
        try await fixture { store, clock, user, _, _ in
            let original = try message(user: user)
            try await store.save(original)
            _ = try await store.prepareRevoke(original, operationID: UUID())
            let checkpoint = ChatCheckpoint(cursor: "0", epoch: "epoch")
            try await store.setMeta(checkpoint, id: "checkpoint")
            let value = revoked(original)
            let messageJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
            let eventJSON: [String: Any] = [
                "base": "0", "next": "1", "epoch": "epoch", "hasMore": false,
                "events": [["position": 1, "kind": "message", "message": messageJSON]],
            ]
            let events = try JSONDecoder().decode(
                ChatEvents.self, from: JSONSerialization.data(withJSONObject: eventJSON))
            clock.advance(10)
            try await store.apply(events: events, expected: checkpoint)
            let deadline = try #require(
                await store.reeditAvailability(conversation: original.conversationID).first?
                    .expiresAt)
            #expect(try await store.checkpoint()?.cursor == "1")
            clock.advance(50)
            try await store.save(value)
            #expect(
                try await store.reeditAvailability(conversation: original.conversationID).first?
                    .expiresAt == deadline)
        }
    }
}
