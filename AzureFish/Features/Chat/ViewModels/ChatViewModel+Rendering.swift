//
//  ChatViewModel+Rendering.swift
//  Demo
//

import AppLocalization
import Foundation

/// 更新界面内容与展示状态。
@available(iOS 16.0, *)
extension ChatViewModel {

    /// 重新生成完整展示状态，并携带指定原因同步调用渲染回调。
    func publish(reason: UpdateReason) {
        state = makeState()
        render?(state, reason)
    }

    /// 将原始消息解析为有序时间线，补充时间分隔、发送状态文字和输入状态项。
    func makeState() -> State {
        var timeline: [TimelineItem] = []
        // 只有已配置来源的会话才加入顶部提示；文案在每次状态生成时按当前语言解析。
        if historyState != .disabled {
            let key: String = switch historyState {
            case .loading: "imessage.history.loading"
            case .failed: "imessage.history.failed"
            case .exhausted: "imessage.history.exhausted"
            case .idle, .disabled: "imessage.history.earlier"
            }
            timeline.append(TimelineItem(id: .historyStatus,
                content: .historyStatus(.init(state: historyState, text: localizer.text(key)))))
        }
        var previousDate: Date?
        let latestOutgoingID = messages.last(where: {
            $0.direction == .outgoing
        })?.id

        for message in messages {
            if previousDate == nil
                || message.sentAt.timeIntervalSince(previousDate!)
                    >= Self.timestampInterval {
                let timestamp = TimestampPresentation(
                    sourceMessageID: message.id,
                    text: Self.timestampText(
                        for: message.sentAt,
                        locale: Localization.localizationController
                            .currentLocale.locale
                    )
                )
                timeline.append(
                    TimelineItem(
                        id: .timestamp(sourceMessageID: message.id),
                        content: .timestamp(timestamp)
                    )
                )
            }

            let deliveryText: String?
            if message.direction == .outgoing, let deliveryState = message.deliveryState,
               message.id == latestOutgoingID || deliveryState == .sending || deliveryState == .failed {
                let key: String = switch deliveryState {
                case .sending: "imessage.status.sending"
                case .delivered: "imessage.status.delivered"
                case .read: "imessage.status.read"
                case .failed: "imessage.status.failed"
                }
                deliveryText = localizer.text(key)
            } else {
                deliveryText = nil
            }

            let presentation: MessagePresentation
            switch message.content {
            case .attachment(let attachment):
                presentation = MessagePresentation(
                    id: message.id,
                    direction: message.direction,
                    attachment: attachment,
                    deliveryText: deliveryText,
                    deliveryState: message.deliveryState
                )
            case .richText(let text):
                presentation = MessagePresentation(
                    id: message.id, direction: message.direction, richText: text,
                    deliveryText: deliveryText, deliveryState: message.deliveryState
                )
            case .localized, .userText:
                presentation = MessagePresentation(
                    id: message.id,
                    direction: message.direction,
                    text: resolvedText(message.content),
                    deliveryText: deliveryText,
                    deliveryState: message.deliveryState
                )
            }
            timeline.append(
                TimelineItem(
                    id: .message(message.id),
                    content: .message(presentation)
                )
            )
            previousDate = message.sentAt
        }

        if isTyping {
            timeline.append(
                TimelineItem(
                    id: .typing,
                    content: .typing(
                        accessibilityLabel: localizer.text(
                            "imessage.typing.accessibility"
                        )
                    )
                )
            )
        }

        return State(timeline: timeline, isTyping: isTyping, isProcessingMessages:
            activeReplyID != nil || !pendingReplies.isEmpty || messages.contains { $0.deliveryState == .sending },
            historyState: historyState)
    }

    /// 解析本地化或用户文本载荷；附件载荷返回空字符串。
    private func resolvedText(_ content: MessageContent) -> String {
        switch content {
        case .localized(let key):
            localizer.text(key)
        case .userText(let text):
            text
        case .richText(let text):
            text.text
        case .attachment:
            ""
        }
    }

    /// 按指定区域设置将日期格式化为不含日期部分的短时间文字。
    private static func timestampText(
        for date: Date,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
