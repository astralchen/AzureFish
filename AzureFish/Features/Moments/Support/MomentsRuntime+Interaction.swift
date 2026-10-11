import Foundation
import AzureFishAPI
import AzureFishMoments
import AzureFishStorage

extension MomentsRuntime {
    /// 先持久化互动请求，再执行网络写入；成功后合并快照并移除待重试记录。
    ///
    /// 网络或其他未知失败保留原请求，明确的 400、403、404、409 响应移除记录。
    func mutate(_ action: MomentsPendingAction) async throws {
        guard let api, let store else { throw AccountStorageError.unavailable }
        if action.kind == .comment {
            guard action.text.count <= 500, action.text.utf8.count <= 16 * 1024, AccountValidation.text(action.text),
                  !action.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIClientError.invalidRequest }
        }
        refreshVersion = UUID(); try await store.save(action)
        pending = try await store.pending(); notify()
        do {
            let post: MomentsPost?
            switch action.kind {
            case .like: post = try await api.like(action.post, liked: action.liked, operation: action.id)
            case .deletePost: post = try await api.delete(action.post, operation: action.id)
            case .comment:
                guard let id = UUID(uuidString: action.comment) else { throw APIClientError.invalidRequest }
                post = try await api.comment(post: action.post, id: id, text: action.text, replyTo: action.replyTo, operation: action.id)
            case .deleteComment: post = try await api.deleteComment(post: action.post, comment: action.comment, operation: action.id)
            case .cover:
                let album = try await api.cover(asset: action.asset, revision: action.revision, operation: action.id)
                try Task.checkCancellation(); try await store.save(album); albums[album.owner.id] = album; post = nil
            }
            try Task.checkCancellation()
            if let post { try await store.merge([post]) }
            try await store.removeAction(action.id); failure = nil; try await restore(); broadcast()
        } catch {
            if isMomentUnavailable(error) { try await store.removePosts([action.post]) }
            if case APIClientError.service(let failure) = error, [400, 403, 404, 409].contains(failure.statusCode) {
                try await store.removeAction(action.id); try await restore()
            }
            throw error
        }
    }
}
