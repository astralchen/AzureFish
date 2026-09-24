//
//  ChatViewModel+Replies.swift
//  Demo
//

import AppLocalization
import Foundation

/// 按顺序调度模拟回复与取消清理。
@available(iOS 16.0, *)
extension ChatViewModel {

    /// 返回附件类型对应的模拟回复计划，语音合成失败仍保持语音类型。
    func replyKind(for attachment: Attachment) -> ReplyKind {
        let reply = attachment.simulatedReply()
        switch attachment {
        case .audio:
            return .synthesizedAudio(
                text: localizer.text("imessage.reply.1"),
                locale: SpeechConfiguration.speechLocale(for: localeProvider()),
                fallback: reply
            )
        case .mediaGroup, .file, .link:
            return .attachment(reply)
        }
    }

    /// 根据消息载荷创建对应回复类型，并将其加入有序待回复集合。
    func enqueueReply(for content: MessageContent, messageID: Int) {
        let kind: ReplyKind
        if case .attachment(let attachment) = content {
            kind = replyKind(for: attachment)
        } else {
            kind = .text
        }
        pendingReplies.append((messageID, kind))
    }

    /// 页面离开时取消整个模拟会话，令迟到送达、已读和回复全部失效。
    func cancelPendingReply() {
        replyGeneration = UUID()
        pendingReplyTask?.cancel()
        pendingReplyTask = nil
        activeReplyID = nil
        pendingReplies.removeAll()
        sendTasks.values.forEach { $0.cancel() }
        sendTasks.removeAll()
        sendAttempts.removeAll()
        for index in messages.indices where messages[index].deliveryState == .sending {
            messages[index].deliveryState = .failed
        }
        isTyping = false
        publish(reason: .messageStatus)
    }

    /// 在队首消息已送达时启动单个回复任务，按顺序模拟阅读和同类型回复。
    ///
    /// 每次挂起后验证回复代次，取消或异常时避免遗留输入状态与工作任务所有权。
    func scheduleReplies() {
        guard pendingReplyTask == nil, let first = pendingReplies.first,
              messages.contains(where: { $0.id == first.messageID &&
                  ($0.deliveryState == .delivered || $0.deliveryState == .read) }) else { return }
        let generation = replyGeneration
        let sleeper = sleeper
        let synthesizer = replyAudioSynthesizer
        activeReplyID = first.messageID
        pendingReplyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let reply = self?.takeNextReply(generation: generation) else { return }
                do {
                    // 模拟对方先查看消息，随后才开始键入；已读不等待附件准备或回复完成。
                    try await sleeper(.milliseconds(300))
                    guard !Task.isCancelled, self?.replyGeneration == generation else { return }
                    self?.receiveReadReceipt(through: reply.messageID)
                    if case .text = reply.kind { self?.setTyping(true) }
                    let content: MessageContent
                    switch reply.kind {
                    case .text:
                        try await sleeper(.milliseconds(900))
                        content = .localized(key: "imessage.reply.1")
                    case .attachment(let attachment):
                        try await sleeper(.milliseconds(900))
                        content = .attachment(attachment)
                    case .synthesizedAudio(let text, let locale, let fallback):
                        async let audio = synthesizer?.synthesizeReplyAudio(text: text, locale: locale)
                        try await sleeper(.milliseconds(900))
                        if let generated = try? await audio {
                            content = .attachment(.audio(generated))
                        } else {
                            content = .attachment(fallback)
                        }
                    }
                    guard !Task.isCancelled, self?.replyGeneration == generation else { return }
                    self?.completeReply(content: content)
                } catch {
                    // 延时/生成任务异常也必须释放队列所有权，不能永久卡在“正在输入”。
                    guard !Task.isCancelled, self?.replyGeneration == generation else { return }
                    self?.finishReplyWorker()
                    self?.scheduleReplies()
                    return
                }
            }
        }
    }

    /// 取出当前代次中已经送达的队首回复请求；无法继续时结束工作状态。
    private func takeNextReply(generation: UUID) -> (messageID: Int, kind: ReplyKind)? {
        guard generation == replyGeneration else { return nil }
        guard let first = pendingReplies.first,
              messages.contains(where: { $0.id == first.messageID &&
                  ($0.deliveryState == .delivered || $0.deliveryState == .read) }) else {
            finishReplyWorker()
            return nil
        }
        activeReplyID = first.messageID
        return pendingReplies.removeFirst()
    }

    /// 仅在输入状态变化时记录新值并发布时间线更新。
    private func setTyping(_ value: Bool) {
        guard isTyping != value else { return }
        isTyping = value
        publish(reason: .messageStatus)
    }

    /// 解除活动回复任务与消息身份，关闭输入状态并发布更新。
    private func finishReplyWorker() {
        pendingReplyTask = nil
        activeReplyID = nil
        isTyping = false
        publish(reason: .messageStatus)
    }

    /// 将回复载荷追加为收到消息，推进消息身份并结束当前输入提示。
    private func completeReply(content: MessageContent) {
        messages.append(Message(
            id: nextMessageID, direction: .incoming, content: content,
            sentAt: clock(), deliveryState: nil
        ))
        nextMessageID += 1
        isTyping = false
        publish(reason: .receivedMessage)
    }
}
