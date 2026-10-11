import Foundation
import AzureFishAPI
import AzureFishMoments

/// 管理编辑草稿、保存与提交；系统媒体访问及其租约由页面协调。
@MainActor
final class MomentsComposerViewModel {
    let runtime: MomentsRuntime
    private(set) var state: MomentsComposerState
    /// 状态变化时在主线程调用；绑定后需由页面主动应用初始 state。
    var render: ((MomentsComposerState) -> Void)?
    var didFinish: (() -> Void)?
    private var saveTask: Task<Void, Never>?
    private var stopped = false
    private var didReleaseDraft = false
    private let epoch: UUID
    private let saveDraft: @MainActor (MomentsDraft) async throws -> Void
    private let sleep: @Sendable () async throws -> Void

    init(runtime: MomentsRuntime, draft: MomentsDraft, cover: Bool = false,
         sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) },
         saveDraft: (@MainActor (MomentsDraft) async throws -> Void)? = nil) {
        self.runtime = runtime
        self.sleep = sleep
        self.saveDraft = saveDraft ?? { try await runtime.save($0) }
        epoch = runtime.epoch
        var value = draft
        if cover { value.isCover = true; value.coverRevision = runtime.albums[runtime.userID]?.revision ?? 0 }
        state = MomentsComposerState(draft: value, isCover: cover || draft.isCover)
    }

    private var active: Bool { !stopped && runtime.epoch == epoch }
    private func notify() { if active { render?(state) } }
    func setBusy(_ value: Bool) { guard active else { return }; state.busy = value; notify() }
    func setError(_ key: String?) { guard active else { return }; state.errorKey = key; notify() }
    func setProgress(_ value: Float) { guard active else { return }; state.progress = value; notify() }

    /// 接收媒体处理结果，账号停止或页面结束后拒绝更新。
    func replaceDraft(_ draft: MomentsDraft) throws {
        try Task.checkCancellation()
        guard active, draft.id == state.draft.id else { throw CancellationError() }
        state.draft = draft
        state.mediaRevision &+= 1
        notify()
    }

    func handle(_ action: MomentsComposerAction) {
        switch action {
        case .textChanged(let value): editText(value)
        case .moveImage(let source, let target): move(source, to: target)
        case .removeImage(let index): remove(index)
        case .removeVideo: removeVideo()
        case .publish: publish()
        case .chooseMedia, .editVideo, .playVideo, .close: break
        }
    }

    /// 更新正文并延迟保存；后续输入取消前一次尚未完成的防抖任务。
    func editText(_ value: String) {
        guard active, state.canEdit else { return }
        state.errorKey = nil
        state.draft.text = value
        state.draft.updatedAt = Date()
        notify()
        cancelPendingSave()
        let snapshot = state.draft
        saveTask = Task { [weak self, sleep] in
            do {
                try await sleep()
                try Task.checkCancellation()
                guard let self, active else { return }
                try await runtime.work { try await self.saveDraft(snapshot) }
            } catch is CancellationError {} catch { self?.setError(momentsErrorKey(error)) }
        }
    }
    /// 请求取消防抖保存，不等待已进入存储层的操作回滚。
    func cancelPendingSave() { saveTask?.cancel(); saveTask = nil }
    private func persist() {
        cancelPendingSave()
        let snapshot = state.draft
        runtime.launch { [runtime] in try await runtime.save(snapshot) }
    }
    private func move(_ source: Int, to target: Int) {
        guard active, state.canEdit, state.draft.images.indices.contains(source), state.draft.images.indices.contains(target) else { return }
        state.draft.images.swapAt(source, target)
        state.draft.updatedAt = Date()
        state.mediaRevision &+= 1
        persist()
        notify()
    }
    private func remove(_ index: Int) {
        guard active, state.canEdit, state.draft.images.indices.contains(index) else { return }
        cancelPendingSave()
        let removed = state.draft.images.remove(at: index), snapshot = state.draft
        state.mediaRevision &+= 1
        runtime.launch { [runtime] in
            // 先移除持久化引用，再尝试释放文件，避免留下指向已删除媒体的草稿。
            try await runtime.save(snapshot)
            if let store = runtime.store, let media = runtime.media { try await store.releaseResource(removed.id, media: media) }
        }
        notify()
    }
    private func removeVideo() {
        guard active, state.canEdit else { return }
        cancelPendingSave()
        setBusy(true)
        runtime.launch { [weak self] in
            guard let self, active else { return }
            defer { setBusy(false) }
            try replaceDraft(await runtime.removeVideo(state.draft))
        }
    }
    /// 先保存当前草稿再提交；失败后重读持久化草稿，以恢复实际冻结和上传状态。
    func publish() {
        guard active, state.canPublish else { return }
        cancelPendingSave()
        state.errorKey = nil
        setBusy(true)
        runtime.launch { [weak self] in
            guard let self, active else { return }
            defer { setBusy(false) }
            do {
                try await runtime.save(state.draft)
                if state.isCover { try await runtime.setCover(state.draft) }
                else {
                    try await runtime.publish(state.draft) { [weak self] fraction in
                        await self?.setProgress(Float(fraction))
                    }
                }
                try Task.checkCancellation()
                guard active else { return }
                releaseDraft()
                didFinish?()
            } catch {
                guard active, !Task.isCancelled else { throw CancellationError() }
                if let value = try await runtime.store?.drafts().first(where: { $0.id == state.draft.id }) { try replaceDraft(value) }
                setError(momentsErrorKey(error))
                throw error
            }
        }
    }
    /// 保存或丢弃后结束编辑；忙碌时忽略请求，已冻结草稿只允许保存退出。
    func leave(save: Bool) {
        guard active, !state.busy, save || !state.frozen else { return }
        cancelPendingSave()
        setBusy(true)
        runtime.launch { [weak self] in
            guard let self, active else { return }
            defer { setBusy(false) }
            if save { try await runtime.save(state.draft) } else { try await runtime.discard(state.draft) }
            try Task.checkCancellation()
            guard active else { return }
            releaseDraft()
            didFinish?()
        }
    }
    /// 页面释放时结束防抖保存并归还草稿占用；账号任务仍归运行时停止屏障管理。
    func stop() {
        guard !stopped else { return }
        stopped = true
        cancelPendingSave()
        releaseDraft()
        render = nil
        didFinish = nil
    }
    private func releaseDraft() {
        guard !didReleaseDraft else { return }
        didReleaseDraft = true
        runtime.release(state.draft.id)
    }
    isolated deinit { cancelPendingSave(); releaseDraft() }
}
