import Fluent
import Foundation

extension IMService {
    /// 在资料保存事务内推进受影响投影；WebSocket 游标提示驱动在线设备拉取。
    func publicProfileChanged(_ user: UUID, db: any Database) async throws {
        IMCommitSignals.current?.insert([user])
        let contacts = try await ContactRecord.query(on: db).group(.or) {
            $0.filter(\.$firstUser == user).filter(\.$secondUser == user)
        }.all()
        for row in contacts {
            let observer = row.firstUser == user ? row.secondUser : row.firstUser
            var state = try contactState(row)
            state.revision += 1
            state.sides?[observer.uuidString]?.revision = state.revision
            // 资料变更不改变申请时间、备注或关系行为；自己的关系投影未变。
            row.payload = try encrypt(state, context: "contact:" + row.requireID().uuidString)
            try await row.update(on: db)
            IMCommitSignals.current?.insert([observer])
            let event = ContactEventRecord(); event.id = UUID(); event.userID = observer; event.peerID = user
            event.position = try await tail(observer, db: db) + 1
            try await event.create(on: db)
        }
        let memberships = try await IMMemberRecord.query(on: db).filter(\.$userID == user).all()
        for membership in memberships {
            guard let row = try await IMConversationRecord.find(membership.conversationID, on: db) else { continue }
            var state: IMConversationState = try decrypt(row.payload, context: "conversation:" + row.requireID().uuidString)
            let viewers = state.members.filter { $0.closedConversation == nil }.map(\.user)
            guard !viewers.isEmpty else { continue }
            state.revision += 1
            try await save(row, state, db: db)
            try await emit(row.requireID(), users: viewers, kind: "conversation", db: db)
        }
    }
}
