import AzureFishAPI
import Foundation

/// 保存评论分页、未提交正文和稳定写身份，网络完成后只发布权威结果。
@MainActor
final class ShortVideoCommentsViewModel {
    let runtime: ShortVideoRuntime
    let video: String
    var draft = ""
    var changed: ((ShortVideoItem) -> Void)?
    var stateChanged: (() -> Void)?
    private(set) var comments: [VideoComment] = []
    private(set) var cursor = "", hasMore = false, busy = false, loading = false
    private(set) var pending: (id: UUID, operation: UUID, text: String)?
    private(set) var pendingDeletes: [String: UUID] = [:]
    private(set) var readVersion = UUID()
    private(set) var errorKey: String?
    private var readTask: Task<Void, Never>?, writeTask: Task<Void, Never>?
    private var observer: UUID?

    init(runtime: ShortVideoRuntime, video: String) {
        self.runtime = runtime; self.video = video
        observer = runtime.observeStop { [weak self] in
            guard let self else { return }
            readTask?.cancel(); writeTask?.cancel(); comments = []; draft = ""
            pending = nil; pendingDeletes = [:]; stateChanged?()
        }
    }
    func stopReading() {
        readTask?.cancel(); readVersion = UUID(); loading = false
    }
    func read(reset: Bool) {
        guard !busy, (!loading || reset), let api = runtime.api else { return }
        readTask?.cancel(); readVersion = UUID(); let version = readVersion
        loading = true; errorKey = nil; stateChanged?()
        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (page, snapshot) = try await runtime.work { [video, cursor] in
                    let page = try await api.comments(video, cursor: reset ? "" : cursor)
                    try Task.checkCancellation()
                    let snapshot = reset ? try await api.get(video) : nil
                    return (page, snapshot)
                }
                try Task.checkCancellation()
                guard readVersion == version else { return }
                if reset { comments = page.comments } else {
                    let known = Set(comments.map(\.id)); comments += page.comments.filter { !known.contains($0.id) }
                }
                cursor = page.cursor; hasMore = page.hasMore
                if let snapshot { changed?(snapshot) }
            } catch is CancellationError {} catch { if readVersion == version { errorKey = shortVideoErrorKey(error) } }
            if readVersion == version { loading = false; stateChanged?() }
        }
    }
    func submit() {
        let text = draft
        guard !busy, let api = runtime.api else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 500 else { errorKey = "shortVideo.invalidComment"; stateChanged?(); return }
        if pending?.text != text { pending = (UUID(), UUID(), text) }
        guard let value = pending else { return }
        stopReading(); busy = true; errorKey = nil; stateChanged?()
        writeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runtime.work { [video] in try await api.comment(video, id: value.id, text: value.text, operation: value.operation) }
                pending = nil; draft = ""; changed?(result); busy = false; read(reset: true)
            } catch is CancellationError {} catch { errorKey = shortVideoErrorKey(error) }
            busy = false; stateChanged?()
        }
    }
    func delete(_ comment: VideoComment) {
        guard !busy, let api = runtime.api else { return }
        stopReading(); busy = true; stateChanged?()
        let operation = pendingDeletes[comment.id] ?? UUID(); pendingDeletes[comment.id] = operation
        writeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runtime.work { [video] in try await api.deleteComment(video, id: comment.id, operation: operation) }
                pendingDeletes[comment.id] = nil; comments.removeAll { $0.id == comment.id }; changed?(result); errorKey = nil
            } catch is CancellationError {} catch { errorKey = shortVideoErrorKey(error) }
            busy = false; stateChanged?()
        }
    }

    isolated deinit {
        readTask?.cancel(); writeTask?.cancel()
        if let observer { runtime.remove(observer) }
    }
}
