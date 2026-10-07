import Fluent
import Foundation

extension IMService {
    /// 老数据以有界页扫描建立全部成员计数；业务修改前调用，结果与消息同事务保存。
    func ensureUnread(_ row: IMConversationRecord, state: inout IMConversationState, db: any Database) async throws {
        let missing = state.members.indices.filter { state.members[$0].unread?.version != 1 }
        guard !missing.isEmpty else { return }
        for index in missing { state.members[index].unread = .init() }
        var after: Int64 = 0
        while true {
            let rows = try await IMMessageRecord.query(on: db).filter(\.$conversationID == row.requireID())
                .filter(\.$sequence > after).filter(\.$sequence <= state.latest)
                .sort(\.$sequence).limit(1000).all()
            for message in rows {
                let value = try storedMessage(message)
                for index in missing where countsUnread(value, member: state.members[index], latest: state.latest) {
                    state.members[index].unread!.count += 1
                }
            }
            guard let last = rows.last, rows.count == 1000 else { break }
            after = last.sequence
        }
        try await save(row, state, db: db)
    }
    func countsUnread(_ message: IMMessage, member: IMMemberState, latest: Int64) -> Bool {
        !message.revoked && message.serverSeq > member.read && message.serverSeq <= member.upperBound(latest)
            && member.sees(message.serverSeq) && message.senderUserID != member.user.uuidString.lowercased()
    }
    /// 发送与撤回只修改仍未阅读且有权查看该消息的成员计数。
    func adjustUnread(_ message: IMMessage, state: inout IMConversationState, delta: Int64) {
        for index in state.members.indices where countsUnread(message, member: state.members[index], latest: state.latest) {
            if state.members[index].unread?.version == 1 {
                state.members[index].unread!.count = max(0, state.members[index].unread!.count + delta)
            }
        }
    }
    /// 阅读推进仅扫描新跨过的序号区间，不重新扫描剩余未读消息。
    func readDelta(_ row: IMConversationRecord, member: IMMemberState, through: Int64, latest: Int64,
                   db: any Database) async throws -> Int64 {
        var after = member.read, count: Int64 = 0
        while after < through {
            let rows = try await IMMessageRecord.query(on: db).filter(\.$conversationID == row.requireID())
                .filter(\.$sequence > after).filter(\.$sequence <= through)
                .sort(\.$sequence).limit(1000).all()
            for row in rows where countsUnread(try storedMessage(row), member: member, latest: latest) { count += 1 }
            guard let last = rows.last, rows.count == 1000 else { break }
            after = last.sequence
        }
        return count
    }
}
