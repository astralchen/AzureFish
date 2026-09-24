import AppLocalization
import Combine
import UIKit

/// 连接聊天页面的草稿快照、批量恢复、后台提交及错误反馈生命周期。
@available(iOS 26.0, *)
extension ChatViewController {
    /// 只收集就绪资源，部分导入的媒体组按原顺序保存就绪子集。
    ///
    /// - Returns: 保留语义正文、用户空白及附件身份的页面快照；不包含导入占位、录音或播放状态。
    func makeDraftSnapshot() -> ChatDraftSnapshot {
        var snapshot = ChatDraftSnapshot(conversationID: conversationID)
        snapshot.segments = composerView.persistentDraftSegments.filter {
            if case .attachment(let id) = $0 { return documentController.drafts[id]?.status == .ready }
            return true
        }
        snapshot.documents = snapshot.segments.compactMap {
            guard case .attachment(let id) = $0 else { return nil }
            return documentController.drafts[id]?.attachment
        }
        if let draft = photoController.draft {
            let items = draft.items.compactMap(\.mediaItem)
            if !items.isEmpty { snapshot.media = .init(id: draft.groupID, items: items) }
        }
        snapshot.audio = audioController.previewAttachment?.audio
        return snapshot
    }

    /// 安装草稿协调器并异步恢复页面内容，同时订阅应用后台与激活通知。
    ///
    /// 在页面交互回调配置完成后调用一次；未注入存储时不启用持久化。
    /// 恢复期间暂停输入和自动保存，待全部控制器安装完成后统一更新布局。
    func configureDraftPersistence() {
        guard let draftStore else { return }
        let coordinator = ChatDraftCoordinator(conversationID: conversationID, store: draftStore)
        draftCoordinator = coordinator
        // 租约保护页面资源直到后台复制完成；其他存储实现至少保持实例存活。
        coordinator.acquireFiles = { [store = attachmentStore] in
            (store as? PageAttachmentStore)?.acquireFileLease() ?? { _ = store }
        }
        coordinator.failed = { [weak self, conversationID] in
            ChatDraftCoordinator.pendingFailures.insert(conversationID)
            self?.pendingDraftNotice = "imessage.draft.saveFailed"
            self?.presentPendingDraftNotice()
        }
        composerView.draftDidChange = { [weak self] in self?.draftContentDidChange() }
        isRestoringDraft = true
        composerView.isUserInteractionEnabled = false
        // 读取也持有租约，避免恢复期间退出页面时目录先被清理、随后又被复制任务重建。
        let release = (attachmentStore as? PageAttachmentStore)?.acquireFileLease()
        let operation = draftStore.load(conversationID: conversationID, into: attachmentStore.directoryURL)
        draftRestoreTask = Task { [weak self] in
            let result = await operation.result
            defer { release?() }
            // 页面真正退出后只释放文件，不再把迟到的恢复结果安装到控制器。
            guard let self, !hasCleanedUpChat else { return }
            defer {
                isRestoringDraft = false
                composerView.isUserInteractionEnabled = true
                draftRestoreTask = nil
                layoutChatContent()
                presentPendingDraftNotice()
            }
            switch result {
            case .success(let result):
                if let snapshot = result.snapshot {
                    UIView.performWithoutAnimation {
                        // 先登记附件，再按语义顺序构造正文，防止内联附件引用尚未存在的条目。
                        documentController.restoreDrafts(snapshot.documents)
                        composerView.restoreDraft(segments: snapshot.segments, documents: documentController.drafts)
                        if let media = snapshot.media { photoController.restoreDraft(media) }
                        if let audio = snapshot.audio { audioController.restoreDraft(audio) }
                        composerView.applyMediaDraft(photoController.draft, animated: false)
                        composerView.applyState(audioController.state)
                    }
                }
                coordinator.restored(makeDraftSnapshot())
                if result.hasMissingAttachments { pendingDraftNotice = "imessage.draft.partialRestore" }
            case .failure:
                coordinator.restored(nil)
                pendingDraftNotice = "imessage.draft.restoreFailed"
            }
        }
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.flushDraftBeforeLeaving() }
            }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.presentPendingDraftNotice() }
            }.store(in: &cancellables)
    }

    /// 将最终内容变更交给协调器，过滤恢复、页面清理及复合动作中的中间状态。
    ///
    /// - Parameter immediately: 是否绕过普通编辑的防抖窗口；附件就绪和生命周期提交时为 `true`。
    func draftContentDidChange(immediately: Bool = false) {
        guard !hasCleanedUpChat, !isRestoringDraft, !isHandlingDraftAction else { return }
        draftCoordinator?.changed(makeDraftSnapshot(), immediately: immediately)
    }

    /// 文件租约先于页面清理取得；UIKit 后台窗口只保护这次有界落盘工作。
    ///
    /// 在页面标记为已清理之前或应用进入后台时调用。恢复尚未结束时跳过，
    /// 避免用页面初始化的空状态覆盖磁盘草稿；本方法不会等待磁盘操作完成。
    func flushDraftBeforeLeaving() {
        guard !isRestoringDraft, !hasCleanedUpChat, let draftCoordinator else { return }
        draftContentDidChange(immediately: true)
        guard let operation = draftCoordinator.flush() else { return }
        var token = UIBackgroundTaskIdentifier.invalid
        token = UIApplication.shared.beginBackgroundTask(withName: "Chat draft") {
            if token != .invalid { UIApplication.shared.endBackgroundTask(token); token = .invalid }
        }
        Task {
            await operation.value
            if token != .invalid { UIApplication.shared.endBackgroundTask(token); token = .invalid }
        }
    }

    /// 在页面可见、应用激活且没有其他模态界面时展示待处理的草稿错误。
    ///
    /// 展示条件不满足时保留提示；跨页面保存失败按会话延迟到下次可展示时消费。
    func presentPendingDraftNotice() {
        guard !hasCleanedUpChat, viewIfLoaded?.window != nil, !isRestoringDraft,
              UIApplication.shared.applicationState == .active, presentedViewController == nil else { return }
        if pendingDraftNotice == nil, ChatDraftCoordinator.pendingFailures.contains(conversationID) {
            pendingDraftNotice = "imessage.draft.saveFailed"
        }
        guard let key = pendingDraftNotice else { return }
        pendingDraftNotice = nil
        ChatDraftCoordinator.pendingFailures.remove(conversationID)
        let alert = UIAlertController(title: nil, message: Localization.text(key), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("imessage.action.ok"), style: .default))
        present(alert, animated: true)
    }
}
