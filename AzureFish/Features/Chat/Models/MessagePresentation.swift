//
//  MessagePresentation.swift
//  Demo
//

import Foundation

/// 完成本地化解析、供时间线单元格直接渲染的消息值。
nonisolated struct MessagePresentation: Equatable, Sendable {
    /// 对应原始消息的稳定标识符。
    let id: Int
    /// 当前消息的接收或发出方向，用于确定气泡外观与语义对齐。
    let direction: MessageDirection
    /// 已解析的正文文本或类型化附件内容。
    let content: MessagePresentationContent
    /// 可选的本地化送达或已读文字。
    let deliveryText: String?
    /// 发出消息的状态；初始化收到消息时强制为 `nil`。
    let deliveryState: MessageDeliveryState?

    /// 创建文本消息的展示模型。
    ///
    /// - Parameters:
    ///   - id: 消息的稳定标识符。
    ///   - direction: 相对于当前用户的收发方向。
    ///   - text: 已完成本地化解析的正文。
    ///   - deliveryText: 可选的送达状态文字。
    ///   - deliveryState: 可选的发送状态；收到消息会忽略此值。
    init(
        id: Int,
        direction: MessageDirection,
        text: String,
        deliveryText: String?,
        deliveryState: MessageDeliveryState? = nil
    ) {
        self.id = id
        self.direction = direction
        content = .text(text)
        self.deliveryText = deliveryText
        self.deliveryState = direction == .outgoing ? deliveryState : nil
    }

    /// 创建保留局部格式的文本展示模型。
    init(id: Int, direction: MessageDirection, richText: MessageText, deliveryText: String?,
         deliveryState: MessageDeliveryState? = nil) {
        self.id = id
        self.direction = direction
        content = .richText(richText)
        self.deliveryText = deliveryText
        self.deliveryState = direction == .outgoing ? deliveryState : nil
    }

    /// 创建附件消息的展示模型。
    ///
    /// - Parameters:
    ///   - id: 消息的稳定标识符。
    ///   - direction: 语义化的接收或发出方向。
    ///   - attachment: 已解析的本地附件。
    ///   - deliveryText: 本地化的送达状态；没有状态时为 `nil`。
    ///   - deliveryState: 发出消息的发送状态；收到消息会忽略此值。
    init(
        id: Int,
        direction: MessageDirection,
        attachment: Attachment,
        deliveryText: String?,
        deliveryState: MessageDeliveryState? = nil
    ) {
        self.id = id
        self.direction = direction
        content = .attachment(attachment)
        self.deliveryText = deliveryText
        self.deliveryState = direction == .outgoing ? deliveryState : nil
    }

    /// 解析后的文本；消息包含任意附件时为空字符串。
    var text: String {
        switch content {
        case .text(let text): text
        case .richText(let text): text.text
        case .attachment: ""
        }
    }

    /// 音频附件；文本或其他类型附件返回 `nil`。
    var audio: AudioAttachment? {
        guard case .attachment(let attachment) = content else { return nil }
        return attachment.audio
    }

    /// 图片和视频媒体组；消息不包含媒体组时为 `nil`。
    var mediaGroup: MediaGroupAttachment? {
        guard case .attachment(let attachment) = content else { return nil }
        return attachment.mediaGroup
    }

    /// ListKit 用于判断已存在消息是否需要重新配置的内容身份。
    var refreshIdentity: MessageRefreshIdentity {
        switch content {
        case .text(let text):
            .text(
                value: text,
                deliveryText: deliveryText,
                direction: direction,
                deliveryState: deliveryState
            )
        case .richText(let text):
            .richText(value: text, deliveryText: deliveryText, direction: direction, deliveryState: deliveryState)
        case .attachment(let attachment):
            .attachment(
                value: attachment,
                deliveryText: deliveryText,
                direction: direction,
                deliveryState: deliveryState
            )
        }
    }
}

/// 消息 Cell 渲染的载荷。
nonisolated enum MessagePresentationContent: Equatable, Sendable {
    /// 已经解析完成、可直接显示的文本。
    case text(String)
    /// 已解析的局部格式文本。
    case richText(MessageText)
    /// 由对应类型的消息单元格呈现的附件。
    case attachment(Attachment)
}

/// 消息 Cell 的稳定刷新身份。
///
/// 类型专属元数据由附件值本身提供；附件内容、发送状态或展示文字变化时，列表
/// 可据此重新配置已有单元格，无须手工拼接文件与尺寸等字符串。
nonisolated enum MessageRefreshIdentity:
    Equatable,
    Hashable,
    Sendable {
    /// 以正文、送达文字、收发方向和发送状态共同判断文本消息是否需要刷新。
    case text(
        value: String,
        deliveryText: String?,
        direction: MessageDirection,
        deliveryState: MessageDeliveryState? = nil
    )
    /// 格式变化同样触发单元格刷新与重新测量。
    case richText(value: MessageText, deliveryText: String?, direction: MessageDirection,
                  deliveryState: MessageDeliveryState? = nil)
    /// 以附件值、送达文字、收发方向和发送状态共同判断附件消息是否需要刷新。
    case attachment(
        value: Attachment,
        deliveryText: String?,
        direction: MessageDirection,
        deliveryState: MessageDeliveryState? = nil
    )
}

/// 时间线分隔项使用的来源消息身份与本地化时间文字。
nonisolated struct TimestampPresentation: Equatable, Sendable {
    /// 触发当前时间分隔项的消息标识符。
    let sourceMessageID: Int
    /// 已经按当前区域设置格式化的时间文字。
    let text: String
}

/// 区分历史提示、时间分隔、消息和输入状态项的稳定时间线身份。
nonisolated enum TimelineItemID: Hashable, Sendable {
    /// 当前会话唯一的顶部历史状态项，状态变化时保持身份稳定。
    case historyStatus
    /// 由来源消息身份确定的时间分隔项。
    case timestamp(sourceMessageID: Int)
    /// 由消息整数标识符确定的消息项。
    case message(Int)
    /// 当前会话唯一的对方输入状态项。
    case typing
}

/// 时间线单项可呈现的内容类型。
nonisolated enum TimelineContent: Equatable, Sendable {
    /// 显示历史加载进度、失败重试或无更多记录提示。
    case historyStatus(HistoryStatusPresentation)
    /// 显示本地化时间分隔信息。
    case timestamp(TimestampPresentation)
    /// 显示已经解析的文本或附件消息。
    case message(MessagePresentation)
    /// 显示对方输入状态，并携带辅助功能描述。
    case typing(accessibilityLabel: String)
}

/// 将稳定列表身份与展示内容组合的时间线项目。
nonisolated struct TimelineItem: Equatable, Sendable {
    /// 供列表差异更新使用的稳定项目身份。
    let id: TimelineItemID
    /// 由对应单元格显示的时间线内容。
    let content: TimelineContent
}
