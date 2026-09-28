import AzureFishAPI
import Foundation
import GRDB

/// 当前设备、账号及会话的偏好；普通退出和清空消息不会重置。
public struct ConversationLocalPreferences: Codable, Sendable, Equatable {
    public var isPinned: Bool
    public var isMuted: Bool
    public init(isPinned: Bool = false, isMuted: Bool = false) {
        self.isPinned = isPinned
        self.isMuted = isMuted
    }
}

/// 按服务端时间及消息 ID 定位下一页，不能跨会话复用。
public struct ChatSearchCursor: Sendable, Equatable {
    public let createdAt: Int64
    public let id: String
}

/// 一页通过当前可见性检查的消息；next 为 nil 时没有更多结果。
public struct ChatSearchPage: Sendable {
    public let messages: [ChatMessage]
    public let next: ChatSearchCursor?
}

/// 生成与界面语言无关的 FTS token，不将用户输入解释为 MATCH 表达式。
enum ChatSearchTokenizer {
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func isHan(_ v: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0x20000...0x323AF).contains(v)
    }
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
    /// 读取当前会话设置；尚未保存时返回关闭置顶及免打扰的默认值。
    public func conversationPreferences(_ conversation: String) throws -> ConversationLocalPreferences {
        try meta("preferences:" + conversation) ?? .init()
    }

    /// 原子保存两个设置；存储关闭或写入失败时抛错并保留旧值。
    public func setConversationPreferences(_ value: ConversationLocalPreferences, conversation: String) throws {
        try setMeta(value, id: "preferences:" + conversation)
    }

    /// 仅更新指定开关，避免两个窗口各自修改不同设置时覆盖对方的值。
    public func updateConversationPreferences(conversation: String, isPinned: Bool? = nil, isMuted: Bool? = nil) throws -> ConversationLocalPreferences {
        try check()
        return try db.write { db in
            let id = "preferences:" + conversation
            let bytes = try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id=?", arguments: [id])
            var value = try bytes.map { try JSONDecoder().decode(ConversationLocalPreferences.self, from: $0) } ?? .init()
            if let isPinned { value.isPinned = isPinned }
            if let isMuted { value.isMuted = isMuted }
            try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES (?,?)", arguments: [id, try JSONEncoder().encode(value)])
            return value
        }
    }

    public func allConversationPreferences() throws -> [String: ConversationLocalPreferences] {
        try check()
        return try db.read { db in
            var result: [String: ConversationLocalPreferences] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id,payload FROM meta WHERE id LIKE 'preferences:%'") {
                let id: String = row["id"], bytes: Data = row["payload"]
                result[String(id.dropFirst("preferences:".count))] = try JSONDecoder().decode(ConversationLocalPreferences.self, from: bytes)
            }
            return result
        }
    }

    /// 返回仍可见且位于当前账号成员区间的消息；搜索及提醒展示前均需复核。
    public func visibleMessage(_ id: String, conversation: String) throws -> ChatMessage? {
        try check()
        return try db.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM entity WHERE bucket='message' AND id=? AND conversation=? AND id NOT IN (SELECT id FROM hidden)", arguments: [id, conversation]) else { return nil }
            let message = try JSONDecoder().decode(ChatMessage.self, from: data)
            return try Self.isAccessible(message, userID: userID, db: db) ? message : nil
        }
    }

    static func isAccessible(_ message: ChatMessage, userID: UUID, db: Database, includingRevoked: Bool = false) throws -> Bool {
        guard includingRevoked || !message.revoked,
              let bytes = try Data.fetchOne(db, sql: "SELECT payload FROM entity WHERE bucket='conversation' AND id=?", arguments: [message.conversationID]) else { return false }
        let conversation = try JSONDecoder().decode(ChatConversation.self, from: bytes)
        guard let member = conversation.members.first(where: { $0.id == userID.uuidString.lowercased() }) else { return false }
        return member.intervals.contains { message.sequence >= $0.joined && ($0.left == 0 || message.sequence < $0.left) }
    }

    /// 搜索已同步到本机的文字；分页按服务端时间及消息 ID 倒序排列。
    public func searchMessages(conversation: String, query: String, before: ChatSearchCursor? = nil, limit: Int = 50) throws -> ChatSearchPage {
        try check()
        let tokens = Array(Set(ChatSearchTokenizer.tokens(String(query.prefix(256))))).sorted()
        guard !tokens.isEmpty else { return .init(messages: [], next: nil) }
        let match = tokens.map { "\"" + $0 + "\"" }.joined(separator: " AND ")
        let size = min(max(limit, 1), 100)
        return try db.read { db in
            var accepted: [ChatMessage] = [], cursor = before
            while accepted.count <= size {
                var sql = "SELECT e.payload FROM entity e JOIN message_search s ON s.id=e.id WHERE e.bucket='message' AND e.conversation=? AND message_search MATCH ? AND e.id NOT IN (SELECT id FROM hidden)"
                var args: StatementArguments = [conversation, match]
                if let cursor {
                    sql += " AND (json_extract(CAST(e.payload AS TEXT),'$.createdAt') < ? OR (json_extract(CAST(e.payload AS TEXT),'$.createdAt') = ? AND e.id < ?))"
                    args += [cursor.createdAt, cursor.createdAt, cursor.id]
                }
                sql += " ORDER BY json_extract(CAST(e.payload AS TEXT),'$.createdAt') DESC,e.id DESC LIMIT 100"
                let data = try Data.fetchAll(db, sql: sql, arguments: args)
                for bytes in data {
                    let message = try JSONDecoder().decode(ChatMessage.self, from: bytes)
                    cursor = .init(createdAt: message.createdAt, id: message.id)
                    if ["text", "link"].contains(message.kind), ChatSearchTokenizer.matchesHanRuns(query, in: message.text), try Self.isAccessible(message, userID: userID, db: db) {
                        accepted.append(message)
                        if accepted.count > size { break }
                    }
                }
                if data.count < 100 { break }
            }
            let values = Array(accepted.prefix(size))
            let next = accepted.count > size ? values.last.map { ChatSearchCursor(createdAt: $0.createdAt, id: $0.id) } : nil
            return .init(messages: values, next: next)
        }
    }

    /// 读取目标周围最多 101 条本地可见消息，不修改草稿和已读水位。
    public func messageContext(_ id: String, conversation: String) throws -> [ChatMessage] {
        guard let target = try visibleMessage(id, conversation: conversation) else { return [] }
        return try db.read { db in
            let left = try Data.fetchAll(db, sql: "SELECT payload FROM entity WHERE bucket='message' AND conversation=? AND sequence<=? AND id NOT IN (SELECT id FROM hidden) ORDER BY sequence DESC LIMIT 51", arguments: [conversation, target.sequence])
            let right = try Data.fetchAll(db, sql: "SELECT payload FROM entity WHERE bucket='message' AND conversation=? AND sequence>? AND id NOT IN (SELECT id FROM hidden) ORDER BY sequence ASC LIMIT 50", arguments: [conversation, target.sequence])
            return try (Array(left.reversed()) + right).map { try JSONDecoder().decode(ChatMessage.self, from: $0) }
                .filter { try Self.isAccessible($0, userID: userID, db: db, includingRevoked: true) }
        }
    }
}
