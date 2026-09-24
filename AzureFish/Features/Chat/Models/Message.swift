//
//  Message.swift
//  Demo
//

import Foundation

/// 消息相对于当前用户的语义收发方向。
nonisolated enum MessageDirection: String, Equatable, Hashable, Sendable {
    /// 由对方发出、当前用户收到的消息。
    case incoming
    /// 由当前用户发出的消息。
    case outgoing
}

/// 发出消息在本地演示发送流程中的状态。
nonisolated enum MessageDeliveryState: String, Equatable, Hashable, Sendable {
    /// 正在等待发送结果。
    case sending
    /// 模拟收件端已确认收到消息。
    case delivered
    /// 消息已被模拟标记为已读。
    case read
    /// 发送失败，可由用户请求重试。
    case failed
}

/// iMessage 聊天消息存储的载荷。
///
/// 本地化文本保留其资源键，以便应用内语言变化后重新生成时间线。用户文本和
/// 附件不会在本地化过程中被改写。
nonisolated enum MessageContent: Equatable, Hashable, Sendable {
    /// 通过资源键延迟解析的本地化文本。
    case localized(key: String)
    /// 保留用户输入内容的普通文本。
    case userText(String)
    /// 保留局部格式的用户文本。
    case richText(MessageText)
    /// 由页面附件存储管理的本地附件。
    case attachment(Attachment)
}

/// 聊天时间线保存的原始消息值，包含身份、载荷、时间和发送状态。
nonisolated struct Message: Equatable, Hashable, Sendable {
    /// 消息在当前会话中的稳定整数标识符。
    let id: Int
    /// 当前消息的接收或发出方向，用于确定气泡外观与语义对齐。
    let direction: MessageDirection
    /// 消息保存的文本或附件载荷，可在转写完成后更新。
    var content: MessageContent
    /// 消息进入会话时记录的日期，用于时间分组。
    let sentAt: Date
    /// 发出消息的发送状态；收到的消息通常为 `nil`。
    var deliveryState: MessageDeliveryState?
}

/// 待插入当前会话的历史消息内容，由视图模型分配本地身份和时间线位置。
///
/// 与历史数据来源无关；加载历史不会触发发送或模拟回复。
nonisolated struct MessageHistoryEntry: Sendable {
    let direction: MessageDirection
    let content: MessageContent
}
