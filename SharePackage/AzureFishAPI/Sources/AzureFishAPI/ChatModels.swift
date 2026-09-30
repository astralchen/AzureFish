import AzureFishProtocol
import Foundation

/// 公开用户资料快照；资料版本独立于联系人关系版本。
public struct ChatUser: Codable, Sendable, Equatable {
    /// 原样保存业务字段及集合顺序；不校验身份、版本或内容，也不执行网络请求。
    public init(id: String, nickname: String, version: Int64, avatarID: String?, deleted: Bool?) {
        self.id = id
        self.nickname = nickname
        self.version = version
        self.avatarID = avatarID
        self.deleted = deleted
    }
    /// 用户的稳定身份。
    public var id: String
    /// 用户公开昵称，保留原始文本。
    public var nickname: String
    /// 公开资料版本，用于独立于关系版本合并昵称及头像。
    public var version: Int64
    /// 头像资源身份；nil 表示没有指定头像。
    public var avatarID: String? = nil
    /// 用户删除状态；nil 表示旧快照未提供该字段。
    public var deleted: Bool? = nil
    /// 将协议响应映射为公开用户资料业务值，保留服务端字段和集合顺序，不执行网络或持久化。
    init(_ value: IMPublicUser) {
        id = value.userID
        nickname = value.nickname
        avatarID = value.avatarID.isEmpty ? nil : value.avatarID
        deleted = value.deleted
        version = value.profileVersion
    }
}

/// 当前账号可见的联系人投影；备注和拉黑设置属于当前账号。
public struct ChatContact: Codable, Sendable, Equatable {
    /// 原样保存业务字段及集合顺序；不校验身份、版本或内容，也不执行网络请求。
    public init(id: String, peer: ChatUser, state: String, requesterID: String, revision: Int64, updatedAt: Int64, semanticsVersion: Int32, isContact: Bool, remark: String, isBlocked: Bool, requestID: String, requestState: String, requestMessage: String, requestUpdatedAt: Int64, availableActions: [String]) {
        self.id = id
        self.peer = peer
        self.state = state
        self.requesterID = requesterID
        self.revision = revision
        self.updatedAt = updatedAt
        self.semanticsVersion = semanticsVersion
        self.isContact = isContact
        self.remark = remark
        self.isBlocked = isBlocked
        self.requestID = requestID
        self.requestState = requestState
        self.requestMessage = requestMessage
        self.requestUpdatedAt = requestUpdatedAt
        self.availableActions = availableActions
    }
    /// 当前联系人关系的稳定身份。
    public var id: String
    /// 对方的公开用户资料快照。
    public var peer: ChatUser
    /// 联系人关系状态原值；新语义使用 isContact、isBlocked 及 availableActions 判定操作。
    public var state: String
    /// 联系人申请发起者的用户身份。
    public var requesterID: String
    /// 此快照的版本号，用于合并时拒绝较旧状态。
    public var revision: Int64
    /// 服务端更新时间，采用 Unix 毫秒时间戳。
    public var updatedAt: Int64
    /// 联系人语义版本；版本 2 才解释显式操作权限。
    public var semanticsVersion: Int32
    /// 对方是否在当前账号的联系人列表中。
    public var isContact: Bool
    /// 当前账号为联系人设置的备注；空字符串表示未设置。
    public var remark: String
    /// 当前账号是否已拉黑对方。
    public var isBlocked: Bool
    /// 联系人申请身份，空字符串表示没有对应申请。
    public var requestID: String
    /// 联系人申请的服务端状态原值。
    public var requestState: String
    /// 联系人申请的验证文字，空字符串表示未填写。
    public var requestMessage: String
    /// 联系人申请更新时间，采用 Unix 毫秒时间戳。
    public var requestUpdatedAt: Int64
    /// 服务端允许执行的动作原值，保留返回顺序；空数组表示无可用动作。
    public var availableActions: [String]
    /// 优先显示非空备注，否则返回对方昵称，不修改原始资料。
    public var displayName: String { remark.isEmpty ? peer.nickname : remark }
    /// 服务端动作集合是否包含 send；本属性不额外检查 semanticsVersion。
    public var canSend: Bool { availableActions.contains("send") }
    /// 关系版本和公共资料版本独立合并，迟到的查询不能恢复旧备注或昵称。
    public func merging(_ other: ChatContact) -> ChatContact {
        guard peer.id == other.peer.id else { return self }
        var result = revision > other.revision ? self : other
        result.peer = peer.version > other.peer.version ? peer : other.peer
        return result
    }
    /// 仅在 semanticsVersion 为 2 且服务端动作集合包含指定操作时返回 true。
    public func allows(_ action: ContactAction) -> Bool { semanticsVersion == 2 && availableActions.contains(action.rawValue) }
    /// 按本地化标准包含规则匹配显示名或昵称；空查询匹配全部联系人。
    public func matches(_ query: String) -> Bool {
        query.isEmpty || displayName.localizedStandardContains(query) || peer.nickname.localizedStandardContains(query)
    }
    /// 将协议响应映射为联系人投影业务值，保留服务端字段和集合顺序，不执行网络或持久化。
    public init(_ value: ContactRelationship) {
        id = value.relationshipID; peer = ChatUser(value.peer); state = value.state
        requesterID = value.requesterUserID; revision = value.revision; updatedAt = value.updatedAtMs
        semanticsVersion = value.semanticsVersion; isContact = value.semanticsVersion == 2 ? value.isContact : value.state == "friend"
        remark = value.remark; isBlocked = value.isBlocked
        requestID = value.requestID; requestState = value.requestState; requestMessage = value.requestMessage
        requestUpdatedAt = value.requestUpdatedAtMs; availableActions = value.availableActions
    }
    private enum CodingKeys: String, CodingKey {
        case id, peer, state, requesterID, revision, updatedAt, semanticsVersion, isContact, remark, isBlocked
        case requestID, requestState, requestMessage, requestUpdatedAt, availableActions
    }
    /// 解码联系人投影并兼容旧数据缺失字段；旧数据没有权限集合时使用空数组，解码错误向上抛出。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); peer = try c.decode(ChatUser.self, forKey: .peer)
        state = try c.decode(String.self, forKey: .state); requesterID = try c.decode(String.self, forKey: .requesterID)
        revision = try c.decode(Int64.self, forKey: .revision); updatedAt = try c.decode(Int64.self, forKey: .updatedAt)
        semanticsVersion = try c.decodeIfPresent(Int32.self, forKey: .semanticsVersion) ?? 0
        isContact = try c.decodeIfPresent(Bool.self, forKey: .isContact) ?? (state == "friend")
        remark = try c.decodeIfPresent(String.self, forKey: .remark) ?? ""
        isBlocked = try c.decodeIfPresent(Bool.self, forKey: .isBlocked) ?? false
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID) ?? ""
        requestState = try c.decodeIfPresent(String.self, forKey: .requestState) ?? ""
        requestMessage = try c.decodeIfPresent(String.self, forKey: .requestMessage) ?? ""
        requestUpdatedAt = try c.decodeIfPresent(Int64.self, forKey: .requestUpdatedAt) ?? 0
        availableActions = try c.decodeIfPresent([String].self, forKey: .availableActions) ?? []
    }
}

/// 成员可见消息的序列区间，起点包含、非零终点不包含。
public struct ChatInterval: Codable, Sendable, Equatable {
    /// 原样保存业务字段及集合顺序；不校验身份、版本或内容，也不执行网络请求。
    public init(joined: Int64, left: Int64) {
        self.joined = joined
        self.left = left
    }
    /// 成员可见消息区间的起始序列，包含此序列。
    public var joined: Int64
    /// 成员可见消息区间的结束序列，不包含此序列；0 表示没有结束边界。
    public var left: Int64
    /// 将协议响应映射为成员可见序列区间业务值，保留服务端字段和集合顺序，不执行网络或持久化。
    init(_ value: IMMembershipInterval) {
        joined = value.joinedSeq
        left = value.leftSeq
    }
}

/// 会话成员的身份、有效状态及历史可见区间。
public struct ChatMember: Codable, Sendable, Equatable {
    /// 原样保存业务字段及集合顺序；不校验身份、版本或内容，也不执行网络请求。
    public init(id: String, active: Bool, intervals: [ChatInterval], profile: ChatUser) {
        self.id = id
        self.active = active
        self.intervals = intervals
        self.profile = profile
    }
    /// 成员的用户身份。
    public var id: String
    /// 该成员是否仍处于会话的有效成员状态。
    public var active: Bool
    /// 服务端给出的成员可见消息区间，保留原顺序，不在模型中合并。
    public var intervals: [ChatInterval]
    /// 该成员的公开用户资料快照。
    public var profile: ChatUser
    /// 将协议响应映射为会话成员业务值，保留服务端字段和集合顺序，不执行网络或持久化。
    init(_ value: IMMember) {
        id = value.userID
        active = value.active
        intervals = value.intervals.map(ChatInterval.init)
        profile = ChatUser(value.profile)
    }
}

/// 当前账号在会话内的已读、送达水位及服务端未读摘要。
public struct ChatReadState: Codable, Sendable, Equatable {
    /// 原样保存业务字段及集合顺序；不校验身份、版本或内容，也不执行网络请求。
    public init(read: Int64, delivered: Int64, unread: Int64, through: Int64, revision: Int64) {
        self.read = read
        self.delivered = delivered
        self.unread = unread
        self.through = through
        self.revision = revision
    }
    /// 当前账号已读到的会话序列，包含此序列。
    public var read: Int64
    /// 当前账号已确认送达到的会话序列，包含此序列。
    public var delivered: Int64
    /// 服务端计算的未读消息数量。
    public var unread: Int64
    /// 该未读摘要所覆盖的会话序列。
    public var through: Int64
    /// 此快照的版本号，用于合并时拒绝较旧状态。
    public var revision: Int64
    /// 将协议响应映射为会话已读状态业务值，保留服务端字段和集合顺序，不执行网络或持久化。
    init(_ value: IMReadState) {
        read = value.readThroughSeq
        delivered = value.deliveredThroughSeq
        unread = value.unreadCount
        through = value.summaryAtSeq
        revision = value.serverRevision
    }
}

/// 服务端会话快照，包括成员、读状态及可选最新消息摘要。
public struct ChatConversation: Codable, Sendable, Equatable {
    /// 原样保存业务字段及集合顺序；不校验身份、版本或内容，也不执行网络请求。
    public init(id: String, kind: String, title: String, ownerID: String, members: [ChatMember], revision: Int64, boundaryRevision: Int64, latest: Int64, closed: Bool, readState: ChatReadState, latestMessage: ChatMessage?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.ownerID = ownerID
        self.members = members
        self.revision = revision
        self.boundaryRevision = boundaryRevision
        self.latest = latest
        self.closed = closed
        self.readState = readState
        self.latestMessage = latestMessage
    }
    /// 聊天会话的稳定身份。
    public var id: String
    /// 服务端会话种类原值，例如 direct 或 group。
    public var kind: String
    /// 服务端会话标题，保留原始文字。
    public var title: String
    /// 群所有者的用户身份；不适用时保留服务端空值。
    public var ownerID: String
    /// 会话成员快照，保留服务端顺序，不在模型中排序或去重。
    public var members: [ChatMember]
    /// 此快照的版本号，用于合并时拒绝较旧状态。
    public var revision: Int64
    /// 成员消息可见边界的服务端版本。
    public var boundaryRevision: Int64
    /// 会话已知的最新服务端消息序列。
    public var latest: Int64
    /// 会话是否已关闭。
    public var closed: Bool
    /// 当前账号的已读、送达水位及未读摘要。
    public var readState: ChatReadState
    /// 服务端提供的最新消息摘要；nil 表示本快照没有摘要，不代表本地历史完整。
    public var latestMessage: ChatMessage?
    /// 将协议响应映射为会话业务值，保留服务端字段和集合顺序，不执行网络或持久化。
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

/// 一条消息的预期、送达和已读人数及独立回执版本。
public struct ChatReceipt: Codable, Sendable, Equatable {
    /// 原样保存业务字段及集合顺序；不校验身份、版本或内容，也不执行网络请求。
    public init(expected: Int64, delivered: Int64, read: Int64, revision: Int64) {
        self.expected = expected
        self.delivered = delivered
        self.read = read
        self.revision = revision
    }
    /// 此消息预期收到回执的成员数量。
    public var expected: Int64
    /// 此消息已确认送达的成员数量。
    public var delivered: Int64
    /// 此消息已确认已读的成员数量。
    public var read: Int64
    /// 此快照的版本号，用于合并时拒绝较旧状态。
    public var revision: Int64
    /// 将协议响应映射为消息回执摘要业务值，保留服务端字段和集合顺序，不执行网络或持久化。
    init(_ value: IMReceiptSummary) {
        expected = value.expectedCount
        delivered = value.deliveredCount
        read = value.readCount
        revision = value.serverRevision
    }
}

/// 媒体资产中的资源清单；不包含下载授权或本地文件路径。
public struct ChatResource: Codable, Sendable, Equatable {
    /// 原样保存业务字段及集合顺序；不校验身份、版本或内容，也不执行网络请求。
    public init(id: String, role: String, filename: String, mime: String, bytes: Int64, sha256: String) {
        self.id = id
        self.role = role
        self.filename = filename
        self.mime = mime
        self.bytes = bytes
        self.sha256 = sha256
    }
    /// 服务端媒体资源的稳定身份。
    public var id: String
    /// 资源在资产中的用途，例如 original 或 thumbnail。
    public var role: String
    /// 资源文件名，仅为元数据，不是本地文件路径。
    public var filename: String
    /// 资源的 MIME 类型字符串。
    public var mime: String
    /// 资源完整长度，单位为字节。
    public var bytes: Int64
    /// 完整资源内容的 SHA-256 十六进制摘要。
    public var sha256: String
    /// 将协议响应映射为媒体资源业务值，保留服务端字段和集合顺序，不执行网络或持久化。
    init(_ value: MediaResource) {
        id = value.resourceID
        role = value.role
        filename = value.filename
        mime = value.mimeType
        bytes = value.byteCount
        sha256 = value.sha256
    }
}

/// 媒体资产的版本化元数据及有序资源清单。
public struct ChatAsset: Codable, Sendable, Equatable {
    /// 原样保存业务字段及集合顺序；不校验身份、版本或内容，也不执行网络请求。
    public init(id: String, kind: String, resources: [ChatResource], width: Int32, height: Int32, duration: Int64, animated: Bool, waveform: [Float], version: Int64) {
        self.id = id
        self.kind = kind
        self.resources = resources
        self.width = width
        self.height = height
        self.duration = duration
        self.animated = animated
        self.waveform = waveform
        self.version = version
    }
    /// 服务端媒体资产的稳定身份。
    public var id: String
    /// 媒体资产种类原值，例如 image、video、audio 或 file。
    public var kind: String
    /// 资产关联的资源清单，保留服务端顺序及每项用途。
    public var resources: [ChatResource]
    /// 媒体宽度，单位为像素。
    public var width: Int32
    /// 媒体高度，单位为像素。
    public var height: Int32
    /// 媒体时长，单位为毫秒。
    public var duration: Int64
    /// 媒体是否包含动画内容。
    public var animated: Bool
    /// 按时间顺序排列的音频波形采样值；空数组表示无波形。
    public var waveform: [Float]
    /// 媒体元数据版本，与资产身份共同构成本地存储键。
    public var version: Int64
    /// 将协议响应映射为媒体资产业务值，保留服务端字段和集合顺序，不执行网络或持久化。
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
    /// 原始文字内容；空字符串表示没有文字，不在存储层本地化。
    public let text: String
    /// 语义格式位掩码；低四位依次表示粗体、斜体、下划线和删除线。
    public let style: UInt32
    /// 保存一段文字及语义格式位；style 默认为 0，不在初始化时校验或屏蔽未知位。
    public init(text: String, style: UInt32 = 0) { self.text = text; self.style = style }
}

/// 由服务端写入的系统事件；未知种类保留原值供占位展示。
public struct ChatSystemEvent: Codable, Sendable, Equatable {
    /// 原样保存业务字段及集合顺序；不校验身份、版本或内容，也不执行网络请求。
    public init(kind: String, relationshipID: String, relationshipRevision: Int64, requesterID: String, accepterID: String) {
        self.kind = kind
        self.relationshipID = relationshipID
        self.relationshipRevision = relationshipRevision
        self.requesterID = requesterID
        self.accepterID = accepterID
    }
    /// 服务端系统事件种类原值；未知种类仍予以保留。
    public let kind: String
    /// 系统事件关联的联系人关系身份。
    public let relationshipID: String
    /// 系统事件对应的联系人关系版本。
    public let relationshipRevision: Int64
    /// 联系人申请发起者的用户身份。
    public let requesterID: String
    /// 接受联系人申请的用户身份。
    public let accepterID: String
    /// 将协议响应映射为系统事件业务值，保留服务端字段和集合顺序，不执行网络或持久化。
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
    /// 当前客户端是否理解此内容类型和版本；未知内容保留字段并展示兼容占位。
    public var isKnownContent: Bool {
        schemaVersion == 1 && ["text", "link", "system", "media_group", "image", "video", "audio", "file"].contains(kind)
    }

    /// 原样保存业务字段及集合顺序；不校验身份、版本或内容，也不执行网络请求。
    public init(id: String, conversationID: String, clientID: String, serverID: String, senderID: String, deviceID: String, sequence: Int64, createdAt: Int64, revision: Int64, kind: String, schemaVersion: Int32, text: String, textRuns: [ChatTextRun]?, linkURL: String?, revoked: Bool, receipt: ChatReceipt, assets: [ChatAsset], systemEvent: ChatSystemEvent?) {
        self.id = id
        self.conversationID = conversationID
        self.clientID = clientID
        self.serverID = serverID
        self.senderID = senderID
        self.deviceID = deviceID
        self.sequence = sequence
        self.createdAt = createdAt
        self.revision = revision
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.text = text
        self.textRuns = textRuns
        self.linkURL = linkURL
        self.revoked = revoked
        self.receipt = receipt
        self.assets = assets
        self.systemEvent = systemEvent
    }
    /// 贯穿本地发送和服务端确认的消息 UUID 字符串。
    public var id: String
    /// 所属聊天会话的稳定身份。
    public var conversationID: String
    /// 客户端生成的消息去重身份；同一次发送重试保持不变。
    public var clientID: String
    /// 服务端分配的消息身份。
    public var serverID: String
    /// 消息发送者的用户身份。
    public var senderID: String
    /// 发起操作的客户端安装身份，不表示硬件认证结果。
    public var deviceID: String
    /// 消息在会话中的服务端序列，用于排序及可见边界判断。
    public var sequence: Int64
    /// 服务端创建时间，采用 Unix 毫秒时间戳。
    public var createdAt: Int64
    /// 此快照的版本号，用于合并时拒绝较旧状态。
    public var revision: Int64
    /// 内容类型原值；与 schemaVersion 一起决定客户端是否能解释正文。
    public var kind: String
    /// 消息内容的协议版本；未知版本应保留并展示兼容占位。
    public var schemaVersion: Int32
    /// 原始文字内容；空字符串表示没有文字，不在存储层本地化。
    public var text: String
    /// 按正文顺序保存的语义格式片段；nil 表示没有提供该字段，空数组与 nil 可区分。
    public var textRuns: [ChatTextRun]?
    /// 链接原文；nil 表示没有附带链接。
    public var linkURL: String?
    /// 消息是否已被服务端确认撤回。
    public var revoked: Bool
    /// 此消息的送达及已读人数摘要，版本独立于消息内容。
    public var receipt: ChatReceipt
    /// 消息中的有序媒体资产；空数组表示没有附件。
    public var assets: [ChatAsset]
    /// 系统消息的事件字段；nil 表示服务端未提供该结构。
    public var systemEvent: ChatSystemEvent?
    /// 将协议响应映射为权威消息业务值，保留服务端字段和集合顺序，不执行网络或持久化。
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

/// 联系人与会话全量快照的一页，完成页携带可提交的同步基线。
public struct ChatSnapshot: Codable, Sendable, Equatable {
    /// 本轮分页快照的服务端标识，后续页需复用。
    public var token: String
    /// 本页会话快照，保留响应顺序。
    public var conversations: [ChatConversation]
    /// 本页联系人快照，保留响应顺序。
    public var contacts: [ChatContact]
    /// 读取下一页快照的游标；是否结束以 complete 为准。
    public var nextCursor: String
    /// 本轮快照是否已全部返回，只有完成页才可提交 baseline。
    public var complete: Bool
    /// 快照完成后开始增量同步的基线游标。
    public var baseline: String
    /// 与游标对应的服务端同步代次。
    public var epoch: String
    /// 将协议响应映射为分页快照业务值，保留服务端字段和集合顺序，不执行网络或持久化。
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

/// 一页历史消息及其分页、连续覆盖和成员可见边界。
public struct ChatHistory: Codable, Sendable, Equatable {
    /// 本页权威历史消息，保留服务端响应顺序。
    public var messages: [ChatMessage]
    /// 本轮分页窗口的固定消息序列上界。
    public var upper: Int64
    /// 后续向前分页使用的排他序列起点。
    public var before: Int64
    /// 当前分页窗口是否还有更早消息。
    public var hasMore: Bool
    /// 服务端确认本页连续覆盖的起始序列；0 表示没有覆盖区间。
    public var coveredFrom: Int64
    /// 服务端确认本页连续覆盖的结束序列，包含此序列。
    public var coveredThrough: Int64
    /// 历史覆盖区间对应的成员可见边界版本。
    public var boundary: Int64
    /// 服务端当前仍可提供的最早消息序列。
    public var earliest: Int64
    /// 将协议响应映射为历史分页业务值，保留服务端字段和集合顺序，不执行网络或持久化。
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

/// 媒体资源的服务端上传身份和分块完成进度。
public struct ChatUploadProgress: Codable, Sendable, Equatable {
    /// 所关联加密媒体资源的稳定身份。
    public var resourceID: String
    /// 服务端为此资源分配的上传会话身份。
    public var uploadID: String
    /// 完整资源需要上传的分块总数。
    public var partCount: Int32
    /// 服务端已接收的从 0 开始的分块序号；调用方可据此跳过已完成分块。
    public var completed: [Int32]
    /// 资源在资产中的用途，例如 original 或 thumbnail。
    public var role: String
    /// 将协议响应映射为资源上传进度业务值，保留服务端字段和集合顺序，不执行网络或持久化。
    init(_ value: MediaUploadProgress) {
        resourceID = value.resourceID
        uploadID = value.uploadID
        partCount = value.partCount
        completed = value.completedParts
        role = value.role
    }
}

/// 媒体资产的版本化元数据及有序资源清单。
public struct ChatAssetStatus: Codable, Sendable, Equatable {
    /// 被查询或创建的媒体资产身份。
    public var id: String
    /// 服务端上传和处理状态原值。
    public var state: String
    /// 资产各资源的上传进度清单。
    public var uploads: [ChatUploadProgress]
    /// 当前媒体资产元数据快照；能否发送仍需检查 state。
    public var asset: ChatAsset
    /// 服务端媒体处理失败码；空字符串表示未提供失败码。
    public var failure: String
    /// 服务端资产状态中的到期时间，采用 Unix 毫秒时间戳。
    public var expiresAt: Int64
    /// 将协议响应映射为媒体资产状态业务值，保留服务端字段和集合顺序，不执行网络或持久化。
    init(_ value: MediaAssetStatus) {
        id = value.assetID
        state = value.state
        uploads = value.uploads.map(ChatUploadProgress.init)
        asset = ChatAsset(value.asset)
        failure = value.failureCode
        expiresAt = value.expiresAtMs
    }
}

/// 一条消息的预期、送达和已读人数及独立回执版本。
public struct ChatReceiptDetail: Codable, Sendable, Equatable {
    /// 回执对应的成员用户身份。
    public var id: String
    /// 该成员是否已确认收到消息。
    public var delivered: Bool
    /// 该成员是否已确认已读消息。
    public var read: Bool
    /// 将协议响应映射为成员回执业务值，保留服务端字段和集合顺序，不执行网络或持久化。
    init(_ value: IMReceiptDetail) {
        id = value.userID
        delivered = value.delivered
        read = value.read
    }
}

/// 一条消息的预期、送达和已读人数及独立回执版本。
public struct ChatReceipts: Codable, Sendable, Equatable {
    /// 当前回执分页快照标识，后续页需复用。
    public var token: String
    /// 此回执快照中的聚合人数和版本。
    public var summary: ChatReceipt
    /// 本页成员回执详情，保留服务端响应顺序。
    public var members: [ChatReceiptDetail]
    /// 下一页回执游标，是否结束以 complete 为准。
    public var nextCursor: String
    /// 此回执快照是否已全部返回。
    public var complete: Bool
    /// 将协议响应映射为回执分页业务值，保留服务端字段和集合顺序，不执行网络或持久化。
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
    /// 事件在账号增量流中的位置，未知事件类型也保留此位置。
    public let position: Int64
    /// 服务端增量事件种类原值。
    public let kind: String
    /// 事件附带的联系人投影；未附带时为 nil。
    public let contact: ChatContact?
    /// 事件附带的会话快照；未附带时为 nil。
    public let conversation: ChatConversation?
    /// 事件附带的消息快照；未附带时为 nil。
    public let message: ChatMessage?
    /// 将协议响应映射为增量事件业务值，保留服务端字段和集合顺序，不执行网络或持久化。
    init(_ value: IMEvent) {
        position = value.position
        kind = value.kind
        contact = value.hasContact ? ChatContact(value.contact) : nil
        conversation = value.hasConversation ? ChatConversation(value.conversation) : nil
        message = value.hasMessage ? ChatMessage(value.message) : nil
    }
}
public struct ChatEvents: Codable, Sendable, Equatable {
    /// 当前用户资料版本提示；非正服务端值映射为 nil。
    public let ownProfileVersion: Int64?
    /// 本页增量事件，保留服务端顺序。
    public let events: [ChatEvent]
    /// 本页开始前的检查点游标，应与本地已提交游标一致。
    public let base: String
    /// 本页实体全部成功提交后才可保存的新检查点游标。
    public let next: String
    /// 与游标对应的服务端同步代次。
    public let epoch: String
    /// 是否需要使用 next 继续拉取下一页。
    public let hasMore: Bool
    /// 将协议响应映射为增量分页业务值，保留服务端字段和集合顺序，不执行网络或持久化。
    init(_ value: IMEventsResponse) {
        ownProfileVersion = value.ownProfileVersion > 0 ? value.ownProfileVersion : nil
        events = value.events.map(ChatEvent.init)
        base = value.baseCursor
        next = value.nextCursor
        epoch = value.epoch
        hasMore = value.hasMore_p
    }
}
