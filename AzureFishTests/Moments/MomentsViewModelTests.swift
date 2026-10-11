import AzureFishAPI
import AzureFishMoments
import Foundation
import Testing
@testable import AzureFish

private actor MomentsSaveGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var count: Int { continuations.count }
    func wait() async { await withCheckedContinuation { continuations.append($0) } }
    func resume() { let pending = continuations; continuations = []; pending.forEach { $0.resume() } }
}

@MainActor
@Suite("朋友圈页面状态", .serialized)
/// 使用可控异步完成时机验证防抖、冻结重试及停止后的状态隔离。
struct MomentsViewModelTests {
    @Test func unavailablePaginationDoesNotChangeTopRefresh() {
        let model = MomentsViewModel(runtime: MomentsPreviewData.runtime())
        var completedRefreshes = 0
        model.didFinishRefresh = { completedRefreshes += 1 }
        for _ in 0..<10 { model.refresh(next: true, retry: false) }
        #expect(completedRefreshes == 0)
        #expect(!model.requestingPage)
        model.refresh()
        #expect(completedRefreshes == 1)
    }

    @Test func feedProjectionKeepsExpansionAndClearsOnAccountStop() async {
        let runtime = MomentsPreviewData.runtime()
        let model = MomentsViewModel(runtime: runtime)
        let post = runtime.posts[0]
        model.toggleExpanded(post.id)
        let album = MomentsViewModel(runtime: runtime, author: post.author.id)
        #expect(album.state.posts == model.state.posts)
        #expect(album.state.expanded.isEmpty)
        model.publishState()
        #expect(model.state.expanded == [post.id])
        #expect(model.state.status == "moments.offline")
        #expect(!model.state.canCompose)
        await runtime.stop().value
        #expect(model.state.posts.isEmpty && model.state.expanded.isEmpty)
    }

    @Test func composerDebounceDropsOldSnapshotsAndStopRejectsLateResults() async throws {
        let runtime = MomentsPreviewData.runtime(), gate = MomentsSaveGate()
        var saved: [String] = []
        let model = MomentsComposerViewModel(runtime: runtime, draft: MomentsDraft(),
            sleep: { await gate.wait() }, saveDraft: { saved.append($0.text) })
        model.editText("first")
        for _ in 0..<100 { if await gate.count == 1 { break }; await Task.yield() }
        model.editText("second")
        for _ in 0..<100 { if await gate.count == 2 { break }; await Task.yield() }
        #expect(await gate.count == 2)
        await gate.resume()
        try await eventually { saved == ["second"] }
        model.editText("stopped")
        for _ in 0..<100 { if await gate.count == 1 { break }; await Task.yield() }
        try #require(await gate.count == 1)
        let snapshot = model.state.draft
        await runtime.stop().value
        await gate.resume()
        #expect(throws: CancellationError.self) { try model.replaceDraft(snapshot) }
        for _ in 0..<20 { await Task.yield() }
        #expect(saved == ["second"])
    }

    @Test func frozenPublicationRejectsEditsAndDiscard() {
        let runtime = MomentsPreviewData.runtime()
        var draft = MomentsDraft(); draft.text = "original"; draft.publication = Data([1, 2, 3])
        let model = MomentsComposerViewModel(runtime: runtime, draft: draft)
        model.editText("changed")
        model.handle(.removeImage(0))
        model.leave(save: false)
        #expect(model.state.draft.id == draft.id)
        #expect(model.state.draft.operation == draft.operation)
        #expect(model.state.draft.text == "original")
        #expect(model.state.frozen && !model.state.canEdit && !model.state.canAdd)
        #expect(model.state.canPublish && !model.state.busy)
    }

    @Test func commentUnknownFailureRetainsIdentityAndRejectsChangedRetry() async throws {
        let runtime = MomentsPreviewData.runtime()
        var attempts: [MomentsPendingAction] = []
        let model = MomentsCommentViewModel(runtime: runtime, post: "post", reply: nil) { action in
            attempts.append(action)
            throw URLError(.networkConnectionLost)
        }
        model.send("  ")
        #expect(model.state.errorKey == "moments.invalid" && attempts.isEmpty)
        model.send("comment")
        model.send("comment")
        try await eventually { !model.state.busy }
        #expect(attempts.count == 1 && !model.state.canEdit)
        model.send("changed")
        #expect(!model.state.busy)
        model.send("comment")
        try await eventually { !model.state.busy }
        #expect(attempts.count == 2)
        #expect(attempts[0].id == attempts[1].id && attempts[0].comment == attempts[1].comment)
        #expect(model.state.errorKey == "moments.failed")
    }

    @Test func stoppedCommentIgnoresLateSuccess() async throws {
        let runtime = MomentsPreviewData.runtime(), gate = MomentsSaveGate()
        var finished = false
        let model = MomentsCommentViewModel(runtime: runtime, post: "post", reply: nil) { _ in await gate.wait() }
        model.didFinish = { finished = true }
        model.send("comment")
        for _ in 0..<100 { if await gate.count == 1 { break }; await Task.yield() }
        try #require(await gate.count == 1)
        await runtime.stop().value
        await gate.resume()
        for _ in 0..<30 { await Task.yield() }
        #expect(!finished)
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("页面状态未在限定时间内完成")
    }
}
