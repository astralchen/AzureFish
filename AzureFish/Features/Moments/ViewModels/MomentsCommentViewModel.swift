import Foundation
import AzureFishAPI
import AzureFishMoments

/// 管理评论校验与重试身份；未知提交结果期间保持输入冻结。
@MainActor
final class MomentsCommentViewModel {
    struct State {
        var busy = false
        var canEdit = true
        var errorKey: String?
    }
    private(set) var state = State()
    private(set) var pendingAction: MomentsPendingAction
    var render: ((State) -> Void)?
    var didFinish: (() -> Void)?
    private let runtime: MomentsRuntime
    private let epoch: UUID
    private let mutate: @MainActor (MomentsPendingAction) async throws -> Void

    init(runtime: MomentsRuntime, post: String, reply: ChatUser?,
         mutate: (@MainActor (MomentsPendingAction) async throws -> Void)? = nil) {
        self.runtime = runtime
        epoch = runtime.epoch
        pendingAction = .init(kind: .comment, post: post, replyTo: reply?.id ?? "")
        self.mutate = mutate ?? { try await runtime.mutate($0) }
    }
    /// 校验并提交评论；结果未知时只能重试原文，明确拒绝后允许修改输入。
    func send(_ value: String) {
        guard !state.busy, runtime.epoch == epoch else { return }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= 500, value.utf8.count <= 16 * 1024, AccountValidation.text(value) else {
            state.errorKey = "moments.invalid"
            render?(state)
            return
        }
        guard state.canEdit || value == pendingAction.text else { return }
        // 只有内容改变才生成新身份；同文重试复用原评论 ID 和操作 ID。
        if pendingAction.text != value {
            pendingAction = .init(kind: .comment, post: pendingAction.post, text: value, replyTo: pendingAction.replyTo)
        }
        state.busy = true
        state.canEdit = false
        render?(state)
        runtime.launch { [weak self] in
            guard let self, runtime.epoch == epoch else { return }
            defer {
                if runtime.epoch == epoch { state.busy = false; render?(state) }
            }
            do {
                try await mutate(pendingAction)
                try Task.checkCancellation()
                guard runtime.epoch == epoch else { return }
                didFinish?()
            } catch {
                guard runtime.epoch == epoch, !Task.isCancelled else { throw CancellationError() }
                state.errorKey = momentsErrorKey(error)
                if case APIClientError.service(let failure) = error, [400, 403, 404, 409].contains(failure.statusCode) { state.canEdit = true }
                throw error
            }
        }
    }
}
