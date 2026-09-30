import Foundation
import AzureFishAPI

/// 与页面文件路径无关的编辑器快照；资源只引用账号加密存储身份。
public struct StoredChatDraft: Sendable, Equatable {
    /// 编辑器快照格式版本，默认 1；当前存储只接受版本 1。
    public var version: Int
    /// 编辑器自身的修订计数，默认 0，不等于服务端消息版本。
    public var revision: UInt64
    /// 所属聊天会话的稳定身份。
    public var conversationID: String
    /// 按编辑器内容顺序保存的文字、格式文字及附件引用；默认空数组。
    public var segments: [StoredDraftSegment]
    /// 编辑器附件清单，保留原顺序，默认空数组。
    public var documents: [StoredDraftAttachment]
    /// 独立媒体组槽位；nil 表示没有该组。
    public var media: StoredDraftMediaGroup?
    /// 独立语音槽位；nil 表示没有语音。
    public var audio: StoredDraftAudio?
    /// 保存编辑器快照；默认版本 1、修订 0、空集合和空媒体槽位，不校验资源是否存在。
    public init(version: Int = 1, revision: UInt64 = 0, conversationID: String, segments: [StoredDraftSegment] = [], documents: [StoredDraftAttachment] = [], media: StoredDraftMediaGroup? = nil, audio: StoredDraftAudio? = nil) {
        self.version = version
        self.revision = revision
        self.conversationID = conversationID
        self.segments = segments
        self.documents = documents
        self.media = media
        self.audio = audio
    }
}

/// 有序语义片段；附件引用稳定身份，保留空白和格式。
public enum StoredDraftSegment: Sendable, Equatable {
    case text(String)
    case richText([ChatTextRun])
    case attachment(UUID)
}
/// 草稿和展示缓存共用的类型化附件描述。
public enum StoredDraftAttachment: Sendable, Equatable {
    case audio(StoredDraftAudio)
    case mediaGroup(StoredDraftMediaGroup)
    case file(StoredDraftFile)
    case link(StoredDraftLink)
    /// 对应附件值的稳定 UUID，供有序片段引用。
    public var id: UUID {
        switch self { case .audio(let v): v.id; case .mediaGroup(let v): v.id; case .file(let v): v.id; case .link(let v): v.id }
    }
    /// 按附件结构收集原图、缩略图等资源身份；不去重，也不验证文件存在。
    public var resourceIDs: [UUID] {
        switch self {
        case .audio(let v): [v.resourceID]
        case .file(let v): [v.resourceID] + [v.thumbnailID].compactMap { $0 }
        case .link(let v): [v.imageID, v.iconID].compactMap { $0 }
        case .mediaGroup(let v): v.items.flatMap { [$0.originalID, $0.thumbnailID] + [$0.pairedVideoID].compactMap { $0 } }
        }
    }
}
/// 语音资源及展示元数据；时长单位为秒。
public struct StoredDraftAudio: Sendable, Equatable {
    /// 此编辑器附件或条目的稳定 UUID，恢复与片段引用时保持不变。
    public var id: UUID
    /// 所关联加密媒体资源的稳定身份。
    public var resourceID: UUID
    /// 语音时长，单位为秒。
    public var duration: Double
    /// 按时间顺序排列的音频波形采样值；空数组表示无波形。
    public var waveform: [Float]
    /// 音频转写文字；nil 表示没有已保存的转写。
    public var transcript: String?
    /// 保存语音资源身份、秒数和有序波形；默认没有转写，不读取文件或检查时长。
    public init(id: UUID, resourceID: UUID, duration: Double, waveform: [Float], transcript: String? = nil) {
        self.id = id
        self.resourceID = resourceID
        self.duration = duration
        self.waveform = waveform
        self.transcript = transcript
    }
}

/// 文件资源及可选缩略图身份。
public struct StoredDraftFile: Sendable, Equatable {
    /// 此编辑器附件或条目的稳定 UUID，恢复与片段引用时保持不变。
    public var id: UUID
    /// 所关联加密媒体资源的稳定身份。
    public var resourceID: UUID
    /// 供界面展示的文件名，不是持久文件地址。
    public var displayName: String
    /// 文件内容的统一类型标识符，供恢复附件展示使用。
    public var typeIdentifier: String
    /// 文件完整长度，单位为字节。
    public var byteCount: Int64
    /// 可选缩略图资源身份；nil 表示没有缩略图。
    public var thumbnailID: UUID?
    /// 保存文件资源和展示元数据；缩略图默认 nil，不读取文件或验证字节数。
    public init(id: UUID, resourceID: UUID, displayName: String, typeIdentifier: String, byteCount: Int64, thumbnailID: UUID? = nil) {
        self.id = id
        self.resourceID = resourceID
        self.displayName = displayName
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
        self.thumbnailID = thumbnailID
    }
}

/// 网页地址与独立加密的封面、图标身份。
public struct StoredDraftLink: Sendable, Equatable {
    /// 此编辑器附件或条目的稳定 UUID，恢复与片段引用时保持不变。
    public var id: UUID
    /// 网页 URL 原文，初始化不校验或发起访问。
    public var url: String
    /// 已缓存的网页标题；nil 表示尚无标题。
    public var title: String?
    /// 网页封面在加密存储中的资源身份；nil 表示没有封面。
    public var imageID: UUID?
    /// 链接图标在加密存储中的资源身份；nil 表示未缓存图标。
    public var iconID: UUID?
    /// 保存网页地址及可选标题、封面和图标；默认没有预览元数据，不执行网络请求。
    public init(id: UUID, url: String, title: String? = nil, imageID: UUID? = nil, iconID: UUID? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.imageID = imageID
        self.iconID = iconID
    }
}

/// 媒体条目；尺寸为像素，视频时长为秒，nil 表示图片。
public struct StoredDraftMediaItem: Sendable, Equatable {
    /// 此编辑器附件或条目的稳定 UUID，恢复与片段引用时保持不变。
    public var id: UUID
    /// 系统相册资产标识；nil 表示来源没有提供此标识。
    public var assetIdentifier: String?
    /// 媒体原始文件在加密存储中的资源身份。
    public var originalID: UUID
    /// 缩略图在加密存储中的资源身份。
    public var thumbnailID: UUID
    /// Live Photo 配对视频的资源身份；nil 表示没有配对视频。
    public var pairedVideoID: UUID?
    /// 媒体宽度，单位为像素。
    public var width: Double
    /// 媒体高度，单位为像素。
    public var height: Double
    /// 视频时长，单位为秒；nil 表示图片条目。
    public var duration: Double?
    /// 媒体是否包含动画内容。
    public var animated: Bool
    /// 保存媒体资源及像素尺寸；相册标识、配对视频和时长默认 nil，动画标记默认 false。
    public init(id: UUID, assetIdentifier: String? = nil, originalID: UUID, thumbnailID: UUID, pairedVideoID: UUID? = nil, width: Double, height: Double, duration: Double? = nil, animated: Bool = false) {
        self.id = id
        self.assetIdentifier = assetIdentifier
        self.originalID = originalID
        self.thumbnailID = thumbnailID
        self.pairedVideoID = pairedVideoID
        self.width = width
        self.height = height
        self.duration = duration
        self.animated = animated
    }
}

/// 保留组身份和用户选择顺序的媒体集合。
public struct StoredDraftMediaGroup: Sendable, Equatable {
    /// 此编辑器附件或条目的稳定 UUID，恢复与片段引用时保持不变。
    public var id: UUID
    /// 按用户选择顺序保存的媒体条目；模型允许空集合且不去重。
    public var items: [StoredDraftMediaItem]
    /// 保存媒体组身份及条目顺序，不校验数量或资源存在性。
    public init(id: UUID, items: [StoredDraftMediaItem]) {
        self.id = id
        self.items = items
    }
}

extension StoredChatDraft {
    /// 从附件、媒体及语音槽位收集的去重资源身份，不包含尚无附件描述的片段引用。
    public var resourceIDs: Set<UUID> {
        var values = documents.flatMap(\.resourceIDs)
        if let media { values += StoredDraftAttachment.mediaGroup(media).resourceIDs }
        if let audio { values.append(audio.resourceID) }
        return Set(values)
    }
}

/// 不确定的联系人写请求；重试必须复用 bytes，不重新编码网络操作。
public struct PendingContactOperation: Sendable {
    /// 原联系人修改请求的完整 Protobuf 字节，重试必须复用，包含用户文字须加密保存。
    public let bytes: Data
    /// 联系人操作的稳定协议值。
    public let action: ContactAction
    /// 当前账号为联系人设置的备注；空字符串表示未设置。
    public let remark: String
    /// 联系人申请随附的原始文字。
    public let message: String
    /// 保存未决请求原始字节和界面恢复字段，不重新编码或验证内容一致性。
    public init(bytes: Data, action: ContactAction, remark: String, message: String) {
        self.bytes = bytes; self.action = action; self.remark = remark; self.message = message
    }
}
