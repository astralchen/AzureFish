//
//  ChatViewModel+Sending.swift
//  Demo
//

import AppLocalization
import Foundation

/// 管理消息发送、重试与阅读回执。
@available(iOS 16.0, *)
extension ChatViewModel {

    /// 移除首尾空白后发送用户输入的文本。
    ///
    /// 文本内部的换行仍会作为消息内容保留。
    ///
    /// - Parameter rawText: 文本编辑器中未经处理的内容。
    /// - Returns: 成功追加非空消息时为 `true`；否则为 `false`。
    @discardableResult
    func send(_ rawText: String) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        appendOutgoing(
            content: .userText(text),
            replyKind: .text
        )
        return true
    }

    /// 通过普通发出消息生命周期发送页面附件。
    ///
    /// 音频与媒体组都在写入时间线前完成文件、尺寸、时长和缩略图校验，并共用
    /// 同一条消息生命周期。
    ///
    /// - Parameter attachment: 已完成预览且仍由页面附件存储持有的附件。
    /// - Returns: 成功追加附件时为 `true`；否则为 `false`。
    @discardableResult
    func sendAttachment(_ attachment: Attachment) -> Bool {
        guard validates(attachment) else { return false }

        appendOutgoing(
            content: .attachment(attachment),
            replyKind: replyKind(for: attachment)
        )
        return true
    }

    /// 以一次时间线事务发送媒体组，并在其后追加可选文字消息。
    ///
    /// 媒体和文字只发布一次发送状态，各消息按顺序获得同类型回复。任一媒体无效时不会产生
    /// 部分时间线写入，调用方可以完整保留 Composer 草稿并重试。
    @discardableResult
    func sendMediaGroup(
        _ group: MediaGroupAttachment,
        followedByText rawText: String
    ) -> Bool {
        sendAttachments([.mediaGroup(group)], followedByText: rawText)
    }

    /// 照片面板媒体组沿用附件优先的兼容入口，统一交给有序事务发送。
    @discardableResult
    func sendAttachments(_ attachments: [Attachment], followedByText rawText: String) -> Bool {
        sendContents(attachments.map { .attachment($0) } + [.userText(rawText)])
    }

    /// 全批验证后按文档顺序一次性发布；失败不写入部分消息，正文不裁剪。
    @discardableResult
    func sendContents(_ contents: [MessageContent]) -> Bool {
        var ids: Set<UUID> = []
        var payloads: [MessageContent] = []
        for content in contents {
            switch content {
            case .attachment(let attachment):
                guard validates(attachment), ids.insert(attachment.id).inserted else { return false }
                payloads.append(content)
            case .userText(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { payloads.append(content) }
            case .richText(let text):
                if !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { payloads.append(content) }
            case .localized: return false
            }
        }
        guard !payloads.isEmpty else { return false }
        let sentAt = clock()
        let firstID = nextMessageID
        for content in payloads {
            enqueueReply(for: content, messageID: nextMessageID)
            messages.append(Message(
                id: nextMessageID, direction: .outgoing, content: content,
                sentAt: sentAt, deliveryState: .sending
            ))
            nextMessageID += 1
        }
        publish(reason: .sentMessage)
        for id in firstID..<nextMessageID { startSending(messageID: id) }
        return true
    }

    /// 验证附件是否满足进入消息时间线的最低条件。
    ///
    /// - Parameter attachment: 即将发送的页面附件。
    /// - Returns: 附件文件和类型专属元数据均有效时为 `true`。
    private func validates(_ attachment: Attachment) -> Bool {
        switch attachment {
        case .file(let file):
            file.fileURL.isFileURL && !file.displayName.isEmpty
                && FileManager.default.isReadableFile(atPath: file.fileURL.path)
                && (try? file.fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        case .link(let link):
            LinkAttachment.accepts(link.url)
        case .audio(let audio):
            RecordingPolicy.accepts(
                duration: audio.duration,
                fileExists: FileManager.default.fileExists(
                    atPath: audio.fileURL.path
                )
            )
        case .mediaGroup(let group):
            !group.items.isEmpty
                && group.items.count <= MediaGroupAttachment
                    .selectionLimit
                && group.items.allSatisfy { item in
                    guard item.pixelSize.width > 0,
                          item.pixelSize.height > 0,
                          FileManager.default.fileExists(
                            atPath: item.originalFileURL.path
                          ),
                          FileManager.default.fileExists(
                            atPath: item.thumbnailFileURL.path
                          ) else {
                        return false
                    }
                    switch item.kind {
                    case .image:
                        return true
                    case .video(let duration):
                        return duration.isFinite && duration > 0
                    }
                }
        }
    }

    /// 追加处于发送中的消息和对应回复请求，发布状态后启动异步发送。
    private func appendOutgoing(content: MessageContent, replyKind: ReplyKind) {
        let messageID = nextMessageID
        pendingReplies.append((messageID, replyKind))
        messages.append(Message(
            id: nextMessageID, direction: .outgoing, content: content,
            sentAt: clock(), deliveryState: .sending
        ))
        nextMessageID += 1
        publish(reason: .sentMessage)
        startSending(messageID: messageID)
    }

    /// 只删除当前会话记录，使对应发送和模拟回复结果失效；共享文件仍由页面持有。
    @discardableResult
    func deleteMessage(id: Int) -> Bool {
        guard messages.contains(where: { $0.id == id }) else { return false }
        sendAttempts[id] = nil
        sendTasks.removeValue(forKey: id)?.cancel()
        pendingReplies.removeAll { $0.messageID == id }
        if activeReplyID == id {
            replyGeneration = UUID()
            pendingReplyTask?.cancel()
            pendingReplyTask = nil
            activeReplyID = nil
            isTyping = false
        }
        messages.removeAll { $0.id == id }
        publish(reason: .messageDeleted)
        scheduleReplies()
        return true
    }

    /// 重试原消息；保持 ID、顺序、附件和发送时间，重复点击不会启动第二次尝试。
    @discardableResult
    func retryMessage(id: Int) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id && $0.direction == .outgoing }),
              messages[index].deliveryState == .failed else { return false }
        messages[index].deliveryState = .sending
        enqueueReply(for: messages[index].content, messageID: id)
        publish(reason: .messageStatus)
        startSending(messageID: id)
        return true
    }

    /// 为尚无活动请求的发送中消息创建新的发送尝试。
    ///
    /// 异步完成后验证取消状态、尝试令牌和消息状态，再应用送达或失败结果。
    private func startSending(messageID: Int) {
        guard let message = messages.first(where: { $0.id == messageID }),
              message.deliveryState == .sending, sendTasks[messageID] == nil else { return }
        let attempt = UUID()
        sendAttempts[messageID] = attempt
        let sender = messageSender
        sendTasks[messageID] = Task { [weak self] in
            let succeeded: Bool
            do {
                try await sender.send(message)
                succeeded = true
            } catch {
                succeeded = false
            }
            // 重试或页面退出可能已替换发送尝试；成功和失败都必须通过同一身份校验。
            guard !Task.isCancelled, let self, sendAttempts[messageID] == attempt,
                  let index = messages.firstIndex(where: { $0.id == messageID }),
                  messages[index].deliveryState == .sending else { return }
            sendTasks[messageID] = nil
            sendAttempts[messageID] = nil
            messages[index].deliveryState = succeeded ? .delivered : .failed
            if !succeeded { pendingReplies.removeAll { $0.messageID == messageID } }
            publish(reason: .messageStatus)
            scheduleReplies()
        }
    }

    /// 收件端阅读回执是独立事件，只推进到指定已存在消息；不根据回复推断已读。
    /// 连续消息的已读进度单调前进，失败和仍在发送的消息不会被提前标记。
    func receiveReadReceipt(through messageID: Int) {
        guard readReceiptsEnabled,
              messages.contains(where: { $0.id == messageID && $0.direction == .outgoing &&
                  ($0.deliveryState == .delivered || $0.deliveryState == .read) }) else { return }
        var changed = false
        for index in messages.indices where messages[index].id <= messageID &&
            messages[index].direction == .outgoing && messages[index].deliveryState == .delivered {
            messages[index].deliveryState = .read
            changed = true
        }
        if changed { publish(reason: .messageStatus) }
    }
}
