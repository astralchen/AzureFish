import AzureFishAPI
import GRDB

/// 通讯录和会话映射；集合读取在同一快照中批量装配子记录。
enum DirectoryRepository {
    /// 保存公开用户资料；已有版本严格更新时忽略传入旧版本。
    static func profile(_ value: ChatUser, in db: Database) throws {
        if let old = try UserProfileRecord.fetchOne(db, key: value.id), old.version > value.version { return }
        try UserProfileRecord(id: value.id, nickname: value.nickname, version: value.version,
                              avatarID: value.avatarID, deleted: value.deleted).upsert(db)
    }
    /// 读取全部公开用户资料并按用户身份索引，不执行网络刷新。
    static func profiles(in db: Database) throws -> [String: ChatUser] {
        Dictionary(uniqueKeysWithValues: try UserProfileRecord.fetchAll(db).map {
            ($0.id, ChatUser(id: $0.id, nickname: $0.nickname, version: $0.version, avatarID: $0.avatarID, deleted: $0.deleted))
        })
    }
    /// 批量装配联系人及其资料、申请和动作；peer 为 nil 时读取全部，必要关联缺失时抛错。
    static func contacts(peer: String? = nil, in db: Database) throws -> [ChatContact] {
        let rows = try (peer.map { ContactRecord.filter(ContactRecord.Columns.peerID == $0) } ?? ContactRecord.all()).fetchAll(db)
        let ids = rows.map(\.peerID)
        let profiles = Dictionary(uniqueKeysWithValues: try UserProfileRecord.filter(ids.contains(UserProfileRecord.Columns.id)).fetchAll(db).map {
            ($0.id, ChatUser(id: $0.id, nickname: $0.nickname, version: $0.version, avatarID: $0.avatarID, deleted: $0.deleted))
        })
        let requests = Dictionary(uniqueKeysWithValues: try ContactRequestRecord.filter(ids.contains(ContactRequestRecord.Columns.peerID)).fetchAll(db).map { ($0.peerID, $0) })
        let actions = Dictionary(grouping: try ContactActionRecord.filter(ids.contains(ContactActionRecord.Columns.peerID)).order(ContactActionRecord.Columns.position).fetchAll(db), by: \.peerID)
        return try rows.map { row in
            guard let peer = profiles[row.peerID], let request = requests[row.peerID] else { throw ChatStoreError.unavailable }
            return ChatContact(id: row.id, peer: peer, state: row.state, requesterID: row.requesterID,
                revision: row.revision, updatedAt: row.updatedAt, semanticsVersion: row.semanticsVersion,
                isContact: row.isContact, remark: row.remark, isBlocked: row.isBlocked,
                requestID: request.requestID, requestState: request.state, requestMessage: request.message,
                requestUpdatedAt: request.updatedAt, availableActions: (actions[row.peerID] ?? []).map(\.action))
        }
    }
    /// 在调用者事务中保存联系人投影、申请和有序动作，公开资料按独立版本合并。
    static func save(_ value: ChatContact, in db: Database) throws {
        try profile(value.peer, in: db)
        try ContactRecord(peerID: value.peer.id, id: value.id, state: value.state, requesterID: value.requesterID,
            revision: value.revision, updatedAt: value.updatedAt, semanticsVersion: value.semanticsVersion,
            isContact: value.isContact, remark: value.remark, isBlocked: value.isBlocked).upsert(db)
        try ContactRequestRecord(peerID: value.peer.id, requestID: value.requestID, state: value.requestState,
            message: value.requestMessage, updatedAt: value.requestUpdatedAt).upsert(db)
        try ContactActionRecord.filter(ContactActionRecord.Columns.peerID == value.peer.id).deleteAll(db)
        for (position, action) in value.availableActions.enumerated() {
            try ContactActionRecord(peerID: value.peer.id, position: position, action: action).insert(db)
        }
    }
    /// 执行会话查询并批量恢复有序成员、可见区间、读状态和摘要，保留查询顺序。
    static func conversations(_ request: QueryInterfaceRequest<ConversationRecord> = ConversationRecord.all(), in db: Database) throws -> [ChatConversation] {
        let rows = try request.fetchAll(db), ids = rows.map(\.id)
        guard !rows.isEmpty else { return [] }
        let profiles = try profiles(in: db)
        let members = Dictionary(grouping: try MemberRecord.filter(ids.contains(MemberRecord.Columns.conversationID))
            .order(MemberRecord.Columns.position).fetchAll(db), by: \.conversationID)
        let intervals = Dictionary(grouping: try MemberIntervalRecord.filter(ids.contains(MemberIntervalRecord.Columns.conversationID))
            .order(MemberIntervalRecord.Columns.position).fetchAll(db), by: \.conversationID)
        let reads = Dictionary(uniqueKeysWithValues: try ReadStateRecord.filter(ids.contains(ReadStateRecord.Columns.conversationID)).fetchAll(db).map { ($0.conversationID, $0) })
        let summaries = Dictionary(uniqueKeysWithValues: try SummaryRepository.fetch(SummaryRecord.filter(ids.contains(SummaryRecord.Columns.conversationID)), in: db).map { ($0.conversationID, $0) })
        return try rows.map { row in
            guard let read = reads[row.id] else { throw ChatStoreError.unavailable }
            let values: [ChatMember] = try (members[row.id] ?? []).map { member in
                guard let profile = profiles[member.userID] else { throw ChatStoreError.unavailable }
                return ChatMember(id: member.userID, active: member.active,
                    intervals: (intervals[row.id] ?? []).filter { $0.memberPosition == member.position }.map { .init(joined: $0.joined, left: $0.left) }, profile: profile)
            }
            return ChatConversation(id: row.id, kind: row.kind, title: row.title, ownerID: row.ownerID,
                members: values, revision: row.revision, boundaryRevision: row.boundaryRevision, latest: row.latest,
                closed: row.closed, readState: .init(read: read.read, delivered: read.delivered, unread: read.unread,
                through: read.through, revision: read.revision), latestMessage: summaries[row.id])
        }
    }
    /// 按会话身份装配一个完整快照；没有根记录时返回 nil。
    static func conversation(_ id: String, in db: Database) throws -> ChatConversation? {
        try conversations(ConversationRecord.filter(ConversationRecord.Columns.id == id), in: db).first
    }
    /// 在调用者事务中替换会话、成员、可见区间、读状态及最新摘要；调用方先完成版本合并。
    static func save(_ value: ChatConversation, in db: Database) throws {
        for member in value.members { try profile(member.profile, in: db) }
        try ConversationRecord(id: value.id, kind: value.kind, title: value.title, ownerID: value.ownerID,
            revision: value.revision, boundaryRevision: value.boundaryRevision, latest: value.latest, closed: value.closed).upsert(db)
        try MemberIntervalRecord.filter(MemberIntervalRecord.Columns.conversationID == value.id).deleteAll(db)
        try MemberRecord.filter(MemberRecord.Columns.conversationID == value.id).deleteAll(db)
        for (position, member) in value.members.enumerated() {
            try MemberRecord(conversationID: value.id, position: position, userID: member.id, active: member.active).insert(db)
            for (index, interval) in member.intervals.enumerated() {
                try MemberIntervalRecord(conversationID: value.id, memberPosition: position, position: index,
                    joined: interval.joined, left: interval.left).insert(db)
            }
        }
        let read = value.readState
        try ReadStateRecord(conversationID: value.id, read: read.read, delivered: read.delivered, unread: read.unread,
            through: read.through, revision: read.revision).upsert(db)
        try SummaryRecord.filter(SummaryRecord.Columns.conversationID == value.id).deleteAll(db)
        if let summary = value.latestMessage { try SummaryRepository.save(summary, in: db) }
    }
}
