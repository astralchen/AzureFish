import AzureFishAPI
import Foundation
import Testing

@testable import AzureFishChat

private actor EmptySyncSessionStore: APISessionStore {
    /// 始终返回 nil，模拟尚无会话的同步测试环境。
    func load(environmentID: String) async throws -> APISessionRecord? { nil }
    /// 接受并忽略记录，不执行持久化，仅用于空会话测试。
    func save(_ record: APISessionRecord, environmentID: String) async throws {}
    /// 不执行操作，保持没有会话的测试状态。
    func clear(environmentID: String) async throws {}
}

@Suite("聊天同步状态")
struct ChatSyncStateTests {
    /// 验证初始及本地变化不冒充同步成功，失败状态保留。
    @Test func initialAndLocalUpdatesDoNotConfirmSyncAndFailureSurvivesLocalChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatStore(url: root.appendingPathComponent("db"),
            key: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            environment: "sync-test", userID: UUID())
        let environment = try APIEnvironment(identifier: "sync-test", baseURL: URL(string: "https://example.invalid")!)
        let manager = APISessionManager(api: AccountAPI(environment: environment), store: EmptySyncSessionStore())
        let engine = ChatEngine(store: store, session: manager)
        var iterator = await engine.updates().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.synchronization == .idle && first?.online == false)
        await engine.changed()
        #expect(await iterator.next()?.synchronization == .idle)
        #expect(try await store.checkpoint() == nil)
        do {
            try await engine.synchronize()
            Issue.record("An unauthenticated engine must fail synchronization")
        } catch {
            #expect(error is APISessionError)
        }
        var failedIterator = await engine.updates().makeAsyncIterator()
        #expect(await failedIterator.next()?.synchronization == .failed)
        await engine.changed()
        #expect(await failedIterator.next()?.synchronization == .failed)
        #expect(try await store.checkpoint() == nil)
        try await store.close()
    }
}
