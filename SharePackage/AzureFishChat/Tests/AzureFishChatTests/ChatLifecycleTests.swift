import AzureFishAPI
import AzureFishNetwork
import AzureFishProtocol
import CryptoKit
import Foundation
import Testing
@testable import AzureFishChat

private actor LifecycleSessionStore: APISessionStore {
    var record: APISessionRecord?
    func load(environmentID: String) -> APISessionRecord? { record }
    func save(_ record: APISessionRecord, environmentID: String) { self.record = record }
    func clear(environmentID: String) { record = nil }
}

/// 允许测试显式交付迟到回包；不响应取消，以检验调用方的代次检查。
private actor LifecycleTransport: HTTPTransport {
    let resource: ChatResource
    let bytes: Data
    var eventCalls = 0
    var contentCalls = 0
    var receivedBytes = 0
    var eventWaiters: [CheckedContinuation<HTTPResponse, Error>] = []
    var contentWaiters: [CheckedContinuation<HTTPResponse, Error>] = []
    init(resource: ChatResource, bytes: Data) { self.resource = resource; self.bytes = bytes }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.hasSuffix("/events") {
            eventCalls += 1
            return try await withCheckedThrowingContinuation { eventWaiters.append($0) }
        }
        if request.url.path.hasSuffix("/authorize") {
            var grant = MediaDownloadGrant()
            grant.resourceID = resource.id; grant.etag = "fixture-etag"
            grant.token = "fictional-grant"; grant.byteCount = resource.bytes
            grant.expiresAtMs = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
            return .init(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try grant.serializedData())
        }
        if request.url.path.hasSuffix("/content") {
            contentCalls += 1
            return try await withCheckedThrowingContinuation { contentWaiters.append($0) }
        }
        throw NetworkError.invalidRequest
    }
    func releaseEvent(_ cursor: String) throws {
        var response = IMEventsResponse()
        response.baseCursor = "baseline"; response.nextCursor = cursor; response.epoch = "epoch"
        eventWaiters.removeFirst().resume(returning: .init(statusCode: 200,
            headers: ["Content-Type": "application/protobuf"], body: try response.serializedData()))
    }
    func releaseContent() {
        receivedBytes += bytes.count
        contentWaiters.removeFirst().resume(returning: .init(statusCode: 206,
            headers: ["ETag": "fixture-etag", "Content-Range": "bytes 0-\(bytes.count - 1)/\(bytes.count)"], body: bytes))
    }
}

@Suite("聊天生命周期与共享下载", .timeLimit(.minutes(1)))
struct ChatLifecycleTests {
    private func fixture(_ root: URL) async throws -> (ChatStore, ChatMediaStore, ChatEngine, ChatTransferQueue, LifecycleTransport, ChatResource) {
        let bytes = Data(repeating: 7, count: 16384)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let resource = ChatResource(id: UUID().uuidString.lowercased(), role: "original", filename: "fixture.bin",
                                    mime: "application/octet-stream", bytes: Int64(bytes.count), sha256: hash)
        let transport = LifecycleTransport(resource: resource, bytes: bytes)
        let environment = try APIEnvironment(identifier: "lifecycle-test", baseURL: URL(string: "https://example.invalid")!)
        let manager = APISessionManager(api: AccountAPI(environment: environment, transport: transport), store: LifecycleSessionStore())
        let user = UUID(), key = Data(repeating: 83, count: 32)
        let token = try SessionToken(rawValue: String(repeating: "a", count: 43))
        try await manager.install(.init(environmentID: environment.identifier, userID: user, deviceID: UUID(), sessionID: UUID(),
            accessToken: token, accessExpiresAt: Date().addingTimeInterval(3600), refreshToken: token,
            refreshExpiresAt: Date().addingTimeInterval(7200), refreshGeneration: 1))
        let store = try ChatStore(url: root.appendingPathComponent("db"), key: key, environment: environment.identifier, userID: user)
        try await store.saveCheckpoint(.init(cursor: "baseline", epoch: "epoch"))
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: key, environment: environment.identifier, userID: user)
        let engine = ChatEngine(store: store, session: manager)
        let queue = ChatTransferQueue(store: store, media: media, session: manager, engine: engine, transport: transport)
        return (store, media, engine, queue, transport, resource)
    }
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Controlled operation did not reach its barrier")
        throw CancellationError()
    }
    @Test func stopDrainsLateSynchronizationAndNewSyncKeepsItsState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, engine, queue, transport, _) = try await fixture(root)
        let old = Task { try await engine.synchronize() }
        try await wait { await transport.eventCalls == 1 }
        let stop = Task { await engine.stop() }
        // 接收到 idle 之前，stop 必须仍在等待迟到传输结束。
        try await Task.sleep(for: .milliseconds(20))
        let restart = Task { await engine.start() }
        try await transport.releaseEvent("old-late")
        await stop.value
        do { try await old.value; Issue.record("Canceled synchronization succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(try await store.checkpoint()?.cursor == "baseline")
        await restart.value
        var state = await engine.updates().makeAsyncIterator()
        #expect(await state.next()?.synchronization != .failed)
        let current = Task { try await engine.synchronize() }
        try await wait { await transport.eventCalls == 2 }
        try await transport.releaseEvent("new-current")
        try await current.value
        try await wait {
            var latest = await engine.updates().makeAsyncIterator()
            return await latest.next()?.synchronization == .synced
        }
        #expect(try await store.checkpoint()?.cursor == "new-current")
        await queue.stop(); await engine.stop(); try await store.close()
    }
    @Test func duplicateDownloadsHaveIndependentCancellationAndCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, media, engine, queue, transport, resource) = try await fixture(root)
        let otherWindow = ChatTransferQueue(store: store, media: media, session: engine.api.session, engine: engine, transport: transport)
        let first = Task { try await queue.download(resource, message: "first") }
        try await wait { await transport.contentCalls == 1 }
        let second = Task { try await otherWindow.download(resource, message: "second") }
        try await Task.sleep(for: .milliseconds(30))
        first.cancel()
        do { _ = try await first.value; Issue.record("Canceled waiter succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(await transport.contentCalls == 1)
        await transport.releaseContent()
        let id = try await second.value
        #expect(try await media.read(id, index: 0).count == 16384)
        #expect(try await queue.download(resource, message: "third") == id)
        #expect(await transport.contentCalls == 1)
        #expect(await transport.receivedBytes == 16384)
        await otherWindow.stop()
        await queue.stop(); await engine.stop(); try await store.close()
    }
    @Test func lastWaiterCancelsUnderlyingTransferAndRetryStartsAfterDrain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, engine, queue, transport, resource) = try await fixture(root)
        let first = Task { try await queue.download(resource, message: "first") }
        try await wait { await transport.contentCalls == 1 }
        first.cancel()
        do { _ = try await first.value; Issue.record("Canceled waiter succeeded") }
        catch { #expect(error is CancellationError) }
        let retry = Task { try await queue.download(resource, message: "retry") }
        await transport.releaseContent()
        try await wait { await transport.contentCalls == 2 }
        await transport.releaseContent()
        #expect(try await retry.value == UUID(uuidString: resource.id))
        await queue.stop(); await engine.stop(); try await store.close()
    }
    @Test func bufferedUpdatesPreserveAffectedConversationsAndStatusDoesNotExpandScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, engine, queue, _, _) = try await fixture(root)
        var updates = await engine.updates().makeAsyncIterator()
        #expect(await updates.next()?.scope == .all)
        await engine.changed(conversation: "first", scope: .messages)
        await engine.changed(scope: [])
        let message = try #require(await updates.next())
        #expect(message.scope == .messages && message.conversations == ["first"])
        await engine.changed(conversation: "second", scope: .transfers)
        await engine.changed(conversation: "third", scope: .messages)
        await engine.changed(scope: [])
        let merged = try #require(await updates.next())
        #expect(merged.scope == [.transfers, .messages])
        #expect(merged.conversations == ["second", "third"])
        await queue.stop(); await engine.stop(); try await store.close()
    }

}
