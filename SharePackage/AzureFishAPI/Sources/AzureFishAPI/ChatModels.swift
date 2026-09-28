import AzureFishProtocol
import Foundation

/// 聊天业务值快照，不向界面暴露 Protobuf。
public struct ChatUser: Codable, Sendable, Equatable {
    public var id: String
    public var nickname: String
    public var version: Int64
    init(_ value: IMPublicUser) {
        id = value.userID
        nickname = value.nickname
        version = value.profileVersion
    }
}

/// 当前好友关系与删除墓碑。
public struct ChatContact: Codable, Sendable, Equatable {
    public var id: String
    public var peer: ChatUser
    public var state: String
    public var requesterID: String
    public var revision: Int64
    public var updatedAt: Int64
    init(_ value: ContactRelationship) {
        id = value.relationshipID
        peer = ChatUser(value.peer)
        state = value.state
        requesterID = value.requesterUserID
        revision = value.revision
        updatedAt = value.updatedAtMs
    }
}

/// 聊天业务值快照，不向界面暴露 Protobuf。
public struct ChatInterval: Codable, Sendable, Equatable {
    public var joined: Int64
    public var left: Int64
    init(_ value: IMMembershipInterval) {
        joined = value.joinedSeq
        left = value.leftSeq
    }
}

/// 聊天业务值快照，不向界面暴露 Protobuf。
public struct ChatMember: Codable, Sendable, Equatable {
    public var id: String
    public var active: Bool
    public var intervals: [ChatInterval]
    public var profile: ChatUser
    init(_ value: IMMember) {
        id = value.userID
        active = value.active
        intervals = value.intervals.map(ChatInterval.init)
        profile = ChatUser(value.profile)
    }
}

/// 聊天业务值快照，不向界面暴露 Protobuf。
public struct ChatReadState: Codable, Sendable, Equatable {
    public var read: Int64
    public var delivered: Int64
    public var unread: Int64
    public var through: Int64
    public var revision: Int64
    init(_ value: IMReadState) {
        read = value.readThroughSeq
        delivered = value.deliveredThroughSeq
        unread = value.unreadCount
        through = value.summaryAtSeq
        revision = value.serverRevision
    }
}

/// 聊天业务值快照，不向界面暴露 Protobuf。
public struct ChatConversation: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var title: String
    public var ownerID: String
    public var members: [ChatMember]
    public var revision: Int64
    public var boundaryRevision: Int64
    public var latest: Int64
    public var closed: Bool
    public var readState: ChatReadState
    public var latestMessage: ChatMessage?
    init(_ value: IMConversation) {
        id = value.conversationID
        kind = value.kind
        title = value.title
        ownerID = value.ownerUserID
        members = value.members.map(ChatMember.init)
        revision = value.serverRevision
        boundaryRevision = value.boundaryRevision
        latest = value.latestSeq
        closed = value.closed
        readState = ChatReadState(value.readState)
        latestMessage = value.hasLatestMessage ? ChatMessage(value.latestMessage) : nil
    }
}

/// 聊天业务值快照，不向界面暴露 Protobuf。
public struct ChatReceipt: Codable, Sendable, Equatable {
    public var expected: Int64
    public var delivered: Int64
    public var read: Int64
    public var revision: Int64
    init(_ value: IMReceiptSummary) {
        expected = value.expectedCount
        delivered = value.deliveredCount
        read = value.readCount
        revision = value.serverRevision
    }
}

/// 聊天业务值快照，不向界面暴露 Protobuf。
public struct ChatResource: Codable, Sendable, Equatable {
    public var id: String
    public var role: String
    public var filename: String
    public var mime: String
    public var bytes: Int64
    public var sha256: String
    init(_ value: MediaResource) {
        id = value.resourceID
        role = value.role
        filename = value.filename
        mime = value.mimeType
        bytes = value.byteCount
        sha256 = value.sha256
    }
}

/// 聊天业务值快照，不向界面暴露 Protobuf。
public struct ChatAsset: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var resources: [ChatResource]
    public var width: Int32
    public var height: Int32
    public var duration: Int64
    public var animated: Bool
    public var waveform: [Float]
    public var version: Int64
    init(_ value: MediaAsset) {
        id = value.assetID
        kind = value.kind
        resources = value.resources.map(ChatResource.init)
        width = value.pixelWidth
        height = value.pixelHeight
        duration = value.durationMs
        animated = value.animated
        waveform = value.waveform
        version = value.metadataVersion
    }
}

/// 与显示字体无关的语义格式片段；style 使用低四位表达粗体、斜体、下划线和删除线。
public struct ChatTextRun: Codable, Sendable, Equatable {
    public let text: String
    public let style: UInt32
    public init(text: String, style: UInt32 = 0) { self.text = text; self.style = style }
}

/// 由服务端写入的系统事件；未知种类保留原值供占位展示。
public struct ChatSystemEvent: Codable, Sendable, Equatable {
    public let kind: String
    public let relationshipID: String
    public let relationshipRevision: Int64
    public let requesterID: String
    public let accepterID: String
    init(_ value: IMSystemEvent) {
        kind = value.kind
        relationshipID = value.relationshipID
        relationshipRevision = value.relationshipRevision
        requesterID = value.requesterUserID
        accepterID = value.accepterUserID
    }
}

/// 不携带临时授权的权威消息快照。
public struct ChatMessage: Codable, Sendable, Equatable {
    public var id: String
    public var conversationID: String
    public var clientID: String
    public var serverID: String
    public var senderID: String
    public var deviceID: String
    public var sequence: Int64
    public var createdAt: Int64
    public var revision: Int64
    public var kind: String
    public var schemaVersion: Int32
    public var text: String
    public var textRuns: [ChatTextRun]?
    public var linkURL: String?
    public var revoked: Bool
    public var receipt: ChatReceipt
    public var assets: [ChatAsset]
    public var systemEvent: ChatSystemEvent?
    init(_ value: IMMessage) {
        id = value.messageUuid
        conversationID = value.conversationID
        clientID = value.clientMessageID
        serverID = value.serverMessageID
        senderID = value.senderUserID
        deviceID = value.deviceID
        sequence = value.serverSeq
        createdAt = value.serverCreatedAtMs
        revision = value.serverRevision
        kind = value.contentType
        schemaVersion = value.contentSchemaVersion
        text = value.text
        textRuns = value.textRuns.map { ChatTextRun(text: $0.text, style: $0.style) }
        linkURL = value.linkURL.isEmpty ? nil : value.linkURL
        revoked = value.revoked
        receipt = ChatReceipt(value.receipt)
        assets = value.assets.map(ChatAsset.init)
        systemEvent = value.hasSystemEvent ? ChatSystemEvent(value.systemEvent) : nil
    }
}

/// 聊天业务值快照，不向界面暴露 Protobuf。
public struct ChatSnapshot: Codable, Sendable, Equatable {
    public var token: String
    public var conversations: [ChatConversation]
    public var contacts: [ChatContact]
    public var nextCursor: String
    public var complete: Bool
    public var baseline: String
    public var epoch: String
    init(_ value: IMSnapshotResponse) {
        token = value.snapshotToken
        conversations = value.conversations.map(ChatConversation.init)
        contacts = value.contacts.map(ChatContact.init)
        nextCursor = value.nextCursor
        complete = value.complete
        baseline = value.baselineCursor
        epoch = value.epoch
    }
}

/// 聊天业务值快照，不向界面暴露 Protobuf。
public struct ChatHistory: Codable, Sendable, Equatable {
    public var messages: [ChatMessage]
    public var upper: Int64
    public var before: Int64
    public var hasMore: Bool
    public var coveredFrom: Int64
    public var coveredThrough: Int64
    public var boundary: Int64
    public var earliest: Int64
    init(_ value: IMHistoryResponse) {
        messages = value.messages.map(ChatMessage.init)
        upper = value.upperBoundSeq
        before = value.nextBeforeSeq
        hasMore = value.hasMore_p
        coveredFrom = value.coveredFromSeq
        coveredThrough = value.coveredThroughSeq
        boundary = value.boundaryRevision
        earliest = value.earliestAvailableSeq
    }
}

/// 聊天业务值快照，不向界面暴露 Protobuf。
public struct ChatUploadProgress: Codable, Sendable, Equatable {
    public var resourceID: String
    public var uploadID: String
    public var partCount: Int32
    public var completed: [Int32]
    public var role: String
    init(_ value: MediaUploadProgress) {
        resourceID = value.resourceID
        uploadID = value.uploadID
        partCount = value.partCount
        completed = value.completedParts
        role = value.role
    }
}

/// 聊天业务值快照，不向界面暴露 Protobuf。
public struct ChatAssetStatus: Codable, Sendable, Equatable {
    public var id: String
    public var state: String
    public var uploads: [ChatUploadProgress]
    public var asset: ChatAsset
    public var failure: String
    public var expiresAt: Int64
    init(_ value: MediaAssetStatus) {
        id = value.assetID
        state = value.state
        uploads = value.uploads.map(ChatUploadProgress.init)
        asset = ChatAsset(value.asset)
        failure = value.failureCode
        expiresAt = value.expiresAtMs
    }
}

/// 聊天业务值快照，不向界面暴露 Protobuf。
public struct ChatReceiptDetail: Codable, Sendable, Equatable {
    public var id: String
    public var delivered: Bool
    public var read: Bool
    init(_ value: IMReceiptDetail) {
        id = value.userID
        delivered = value.delivered
        read = value.read
    }
}

/// 聊天业务值快照，不向界面暴露 Protobuf。
public struct ChatReceipts: Codable, Sendable, Equatable {
    public var token: String
    public var summary: ChatReceipt
    public var members: [ChatReceiptDetail]
    public var nextCursor: String
    public var complete: Bool
    init(_ value: IMReceiptsResponse) {
        token = value.snapshotToken
        summary = ChatReceipt(value.summary)
        members = value.members.map(ChatReceiptDetail.init)
        nextCursor = value.nextCursor
        complete = value.complete
    }
}

/// 增量刷新事件中的可选实体；未知类型仍保留事件位置。
public struct ChatEvent: Codable, Sendable, Equatable {
    public let position: Int64
    public let kind: String
    public let contact: ChatContact?
    public let conversation: ChatConversation?
    public let message: ChatMessage?
    init(_ value: IMEvent) {
        position = value.position
        kind = value.kind
        contact = value.hasContact ? ChatContact(value.contact) : nil
        conversation = value.hasConversation ? ChatConversation(value.conversation) : nil
        message = value.hasMessage ? ChatMessage(value.message) : nil
    }
}
public struct ChatEvents: Codable, Sendable, Equatable {
    public let events: [ChatEvent]
    public let base: String
    public let next: String
    public let epoch: String
    public let hasMore: Bool
    init(_ value: IMEventsResponse) {
        events = value.events.map(ChatEvent.init)
        base = value.baseCursor
        next = value.nextCursor
        epoch = value.epoch
        hasMore = value.hasMore_p
    }
}
