import AzureFishAPI
import Foundation
import GRDB

/// 当前设备、账号及会话的偏好；普通退出和清空消息不会重置。
public struct ConversationLocalPreferences: Codable, Sendable, Equatable {
    /// 当前账号在本机是否将会话置顶。
    public var isPinned: Bool
    /// 当前账号在本机是否将会话设为免打扰。
    public var isMuted: Bool
    /// 创建会话本机偏好；默认不置顶、不免打扰，不执行持久化。
    public init(isPinned: Bool = false, isMuted: Bool = false) {
        self.isPinned = isPinned
        self.isMuted = isMuted
    }
}

/// 按服务端时间及消息 ID 定位下一页，不能跨会话复用。
public struct ChatSearchCursor: Sendable, Equatable {
    /// 上一页最后一条消息的服务端创建时间，采用 Unix 毫秒时间戳。
    public let createdAt: Int64
    /// 上一页最后一条消息身份，在时间相同时作为稳定分页的次级排序键。
    public let id: String
}

/// 一页通过当前可见性检查的消息；next 为 nil 时没有更多结果。
public struct ChatSearchPage: Sendable {
    /// 按服务端创建时间和消息身份降序排列的可见搜索结果。
    public let messages: [ChatMessage]
    /// 下一页游标；nil 表示本次查询没有更多通过过滤的结果。
    public let next: ChatSearchCursor?
}

/// 生成与界面语言无关的 FTS token，不将用户输入解释为 MATCH 表达式。
enum ChatSearchTokenizer {
    /// 进行 Unicode 兼容规范化及固定 en_US_POSIX 不区分大小写折叠，使搜索不依赖界面语言。
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
    /// 判断 Unicode 标量是否落在当前分词器支持的汉字区段。
    private static func isHan(_ v: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0x20000...0x323AF).contains(v)
    }
    /// 验证查询中的每个连续汉字串均按原顺序出现在规范化正文中，过滤仅 token 命中的误匹配。
    static func matchesHanRuns(_ query: String, in text: String) -> Bool {
        let normalizedText = normalized(text)
        var run = ""
        for scalar in normalized(query).unicodeScalars {
            if isHan(scalar.value) { run.unicodeScalars.append(scalar) }
            else if !run.isEmpty {
                guard normalizedText.contains(run) else { return false }
                run = ""
            }
        }
        return run.isEmpty || normalizedText.contains(run)
    }
    /// 将汉字单字、相邻双字及其他字母数字词转换为安全十六进制 token；保持产生顺序，允许重复。
    static func tokens(_ text: String) -> [String] {
        let normalized = normalized(text)
        var result: [String] = [], word = "", previousHan: UInt32?
        func flush() {
            if !word.isEmpty {
                result.append("w" + word.utf8.map { String(format: "%02x", $0) }.joined())
                word = ""
            }
        }
        for scalar in normalized.unicodeScalars {
            let v = scalar.value
            let han = isHan(v)
            if han {
                flush()
                result.append("h" + String(v, radix: 16))
                if let previousHan { result.append("b" + String(previousHan, radix: 16) + "z" + String(v, radix: 16)) }
                previousHan = v
            } else {
                previousHan = nil
                if CharacterSet.alphanumerics.contains(scalar) || (!word.isEmpty && CharacterSet.nonBaseCharacters.contains(scalar)) {
                    word.unicodeScalars.append(scalar)
                } else { flush() }
            }
        }
        flush()
        return result
    }
}

extension ChatStore {
    /// 读取指定会话的本机偏好；没有记录时默认不置顶、不免打扰。
    public func conversationPreferences(_ conversation: String) throws -> ConversationLocalPreferences {
        try check()
        return try db.read { db in
            try PreferenceRecord.fetchOne(db, key: conversation).map { .init(isPinned: $0.isPinned, isMuted: $0.isMuted) } ?? .init()
        }
    }
    /// 整体替换会话的置顶和免打扰偏好；多窗口局部修改优先使用 updateConversationPreferences。
    public func setConversationPreferences(_ value: ConversationLocalPreferences, conversation: String) throws {
        try check(); try db.write { try PreferenceRecord(conversationID: conversation, isPinned: value.isPinned, isMuted: value.isMuted).upsert($0) }
    }
    /// 只更新指定偏好，避免多窗口对不同字段的修改相互覆盖。
    public func updateConversationPreferences(conversation: String, isPinned: Bool? = nil, isMuted: Bool? = nil) throws -> ConversationLocalPreferences {
        try check()
        return try db.write { db in
            var row = try PreferenceRecord.fetchOne(db, key: conversation) ?? .init(conversationID: conversation, isPinned: false, isMuted: false)
            if let isPinned { row.isPinned = isPinned }; if let isMuted { row.isMuted = isMuted }
            try row.upsert(db)
            return .init(isPinned: row.isPinned, isMuted: row.isMuted)
        }
    }
    /// 返回按会话身份索引的已保存偏好；缺失项由调用方采用默认值。
    public func allConversationPreferences() throws -> [String: ConversationLocalPreferences] {
        try check()
        return try db.read { db in Dictionary(uniqueKeysWithValues: try PreferenceRecord.fetchAll(db).map { ($0.conversationID, .init(isPinned: $0.isPinned, isMuted: $0.isMuted)) }) }
    }
    /// 读取指定会话中未隐藏、未撤回且处于当前账号成员可见区间的消息；不可见或不存在时返回 nil。
    public func visibleMessage(_ id: String, conversation: String) throws -> ChatMessage? {
        try check()
        return try db.read { db in
            guard let value = try MessageRepository.fetch(Self.visibleMessages(conversation).filter(MessageRecord.Columns.id == id), in: db).first,
                  try Self.isAccessible(value, userID: userID, db: db) else { return nil }; return value
        }
    }
    /// 按当前账号成员区间验证消息序列；默认排除撤回消息，includingRevoked 可放宽撤回检查。
    static func isAccessible(_ message: ChatMessage, userID: UUID, db: Database, includingRevoked: Bool = false) throws -> Bool {
        guard includingRevoked || !message.revoked,
              let conversation = try DirectoryRepository.conversation(message.conversationID, in: db),
              let member = conversation.members.first(where: { $0.id == userID.uuidString.lowercased() }) else { return false }
        return member.intervals.contains { message.sequence >= $0.joined && ($0.left == 0 || message.sequence < $0.left) }
    }
    /// 搜索已同步文字；分页使用服务端时间和消息身份，用户输入不作为 MATCH 语法。
    public func searchMessages(conversation: String, query: String, before: ChatSearchCursor? = nil, limit: Int = 50) throws -> ChatSearchPage {
        try check()
        let tokens = Array(Set(ChatSearchTokenizer.tokens(String(query.prefix(256))))).sorted()
        guard !tokens.isEmpty else { return .init(messages: [], next: nil) }
        let size = min(max(limit, 1), 100)
        return try db.read { db in
            let match = try FTS5Pattern(rawPattern: tokens.map { "\"" + $0 + "\"" }.joined(separator: " AND "))
            let base = Self.visibleMessages(conversation).filter(SearchRecord.matching(match).select(SearchRecord.Columns.id).contains(MessageRecord.Columns.id))
            let membership = try DirectoryRepository.conversation(conversation, in: db)?.members.first { $0.id == userID.uuidString.lowercased() }
            var accepted: [ChatMessage] = [], cursor = before
            while accepted.count <= size {
                var request = base
                if let cursor {
                    request = request.filter(MessageRecord.Columns.createdAt < cursor.createdAt ||
                        (MessageRecord.Columns.createdAt == cursor.createdAt && MessageRecord.Columns.id < cursor.id))
                }
                let values = try MessageRepository.fetch(request.order(MessageRecord.Columns.createdAt.desc, MessageRecord.Columns.id.desc).limit(100), in: db)
                for message in values {
                    cursor = .init(createdAt: message.createdAt, id: message.id)
                    let accessible: Bool = (membership?.intervals ?? []).contains(where: { message.sequence >= $0.joined && ($0.left == 0 || message.sequence < $0.left) })
                    if !message.revoked, accessible, ["text", "link"].contains(message.kind), ChatSearchTokenizer.matchesHanRuns(query, in: message.text) {
                        accepted.append(message)
                        if accepted.count > size { break }
                    }
                }
                if values.count < 100 { break }
            }
            let page = Array(accepted.prefix(size))
            return .init(messages: page, next: accepted.count > size ? page.last.map { .init(createdAt: $0.createdAt, id: $0.id) } : nil)
        }
    }
    /// 以可见目标消息为中心读取至多 50 条前文和 50 条后文并过滤权限，按序列升序返回。
    public func messageContext(_ id: String, conversation: String) throws -> [ChatMessage] {
        try check()
        return try db.read { db in
            guard let target = try MessageRepository.fetch(Self.visibleMessages(conversation).filter(MessageRecord.Columns.id == id), in: db).first,
                  try Self.isAccessible(target, userID: userID, db: db) else { return [] }
            let base = Self.visibleMessages(conversation)
            let left = try MessageRepository.fetch(base.filter(MessageRecord.Columns.sequence <= target.sequence).order(MessageRecord.Columns.sequence.desc).limit(51), in: db)
            let right = try MessageRepository.fetch(base.filter(MessageRecord.Columns.sequence > target.sequence).order(MessageRecord.Columns.sequence).limit(50), in: db)
            let member = try DirectoryRepository.conversation(conversation, in: db)?.members.first { $0.id == userID.uuidString.lowercased() }
            return (left.reversed() + right).filter { message in
                !message.revoked && (member?.intervals.contains { message.sequence >= $0.joined && ($0.left == 0 || message.sequence < $0.left) } ?? false)
            }
        }
    }
}
