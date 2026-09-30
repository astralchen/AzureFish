import AzureFishChat
import AzureFishStorage
import Foundation
import Testing
@testable import AzureFish

@MainActor
@Suite("账号共享存储所有权")
struct ChatAccountStorageTests {
    @Test func simultaneousBorrowersShareAndLastReleaseCloses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = UUID(), key = Data(repeating: 65, count: 32)
        async let first = AccountBusinessStorage.acquire(root: root, databaseKey: key, mediaKey: key, environment: "ownership-test", userID: user)
        async let second = AccountBusinessStorage.acquire(root: root, databaseKey: key, mediaKey: key, environment: "ownership-test", userID: user)
        let (one, two) = try await (first, second)
        #expect(one.resources.database === two.resources.database)
        #expect(one.resources.media === two.resources.media)
        let chat = try ChatStore(database: one.resources.database)
        let other = try ChatStore(database: two.resources.database)
        try await chat.saveDraft(.init(text: "shared"), conversation: "fixture")
        try await chat.close(); try await one.release()
        #expect(try await other.draft("fixture").text == "shared")
        try await other.close(); try await two.release()
        #expect(throws: (any Error).self) { try two.resources.database.read { _ in () } }
        let reopened = try await AccountBusinessStorage.acquire(root: root, databaseKey: key, mediaKey: key, environment: "ownership-test", userID: user)
        let restored = try ChatStore(database: reopened.resources.database)
        #expect(try await restored.draft("fixture").text == "shared")
        try await restored.close(); try await reopened.release()
    }
}
