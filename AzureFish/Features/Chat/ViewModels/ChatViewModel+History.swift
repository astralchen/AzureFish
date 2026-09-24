import Foundation

/// 管理历史来源、单个活动请求、来源身份去重和页面退出后的结果失效。
@available(iOS 16.0, *)
extension ChatViewModel {
    /// 为尚未配置且未失效的会话设置历史来源，并发布可加载状态。
    ///
    /// 本方法不启动请求。重复配置不替换现有来源；fixture 和无来源的注入入口保持原有行为。
    /// - Parameter source: 本次会话使用的数据源，负责游标解释与未接收资源的回收。
    func configureHistory(source: any MessageHistoryLoading) {
        guard historySource == nil, !historyInvalidated else { return }
        historySource = source
        historyState = .idle
        publish(reason: .historyStatus)
    }

    /// 请求最新历史或下一批更早记录，同一时间只允许一个活动请求。
    ///
    /// 首次请求 38 条，后续请求 20 条；成功后才推进游标。导入只修改历史消息与展示状态，
    /// 不创建发送任务或模拟回复。失败由显式重试触发，滚动不会不断重发失败请求。
    /// - Parameter retrying: 是否允许重试失败的当前页；默认仅在空闲状态发起加载。
    func loadHistory(retrying: Bool = false) {
        guard let source = historySource, !historyInvalidated, historyTask == nil,
              historyState == .idle || (retrying && historyState == .failed) else { return }
        let cursor = historyCursor
        let initial = !hasLoadedHistoryPage
        let generation = UUID()
        historyGeneration = generation
        historyState = .loading
        // 先建立任务再发布，避免渲染回调重入产生第二个请求。
        // 仅在结果返回后取得模型的强引用，避免等待来源期间延长页面或模型的生命周期。
        historyTask = Task { [weak self] in
            do {
                let page = try await source.loadPage(before: cursor, limit: initial ? 38 : 20)
                // 不能只依赖来源响应取消：页面已退出或请求身份失效时也必须拒绝迟到结果。
                guard !Task.isCancelled, let self, !historyInvalidated,
                      historyGeneration == generation else { source.discard(page); return }
                historyTask = nil
                var imported: [Message] = []
                // 来源身份映射不随消息删除而清空，避免重叠页面让用户删除的历史重新出现。
                for item in page.messages where historySourceIDs[item.sourceID] == nil {
                    let id = nextMessageID
                    nextMessageID += 1
                    historySourceIDs[item.sourceID] = id
                    imported.append(Message(id: id, direction: item.direction, content: item.content,
                        sentAt: item.sentAt, deliveryState: item.direction == .outgoing ? .read : nil))
                }
                // 只在头部追加新的历史，保留请求期间发送和收到的消息及其本地身份。
                messages.insert(contentsOf: imported, at: 0)
                hasLoadedHistoryPage = true
                historyCursor = page.nextCursor
                historyState = page.nextCursor == nil ? .exhausted : .idle
                publish(reason: initial ? .historyLoaded : .olderHistoryLoaded)
            } catch {
                // 失败不推进游标；退出后的旧请求也不能把已清理会话改成可重试状态。
                guard let self, !historyInvalidated, historyGeneration == generation else { return }
                historyTask = nil
                historyState = Task.isCancelled ? .idle : .failed
                publish(reason: .historyStatus)
            }
        }
        publish(reason: .historyStatus)
    }

    /// 永久停用当前会话的历史加载，并取消活动请求。
    ///
    /// 页面退出或释放时调用；先更换请求身份再取消任务，即使来源忽略取消并返回结果，
    /// 也只能丢弃该页。已接收的附件由页面存储统一清理，本方法不删除已加载消息。
    func cancelHistory() {
        historyInvalidated = true
        historyGeneration = UUID()
        historyTask?.cancel()
        historyTask = nil
    }
}
