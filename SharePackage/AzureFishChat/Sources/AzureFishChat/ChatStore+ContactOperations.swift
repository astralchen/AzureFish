import AzureFishAPI
import GRDB

extension ChatStore {
    /// 读取指定联系人的未决操作及原始字节；没有记录时返回 nil，未知动作抛错。
    public func pendingContactOperation(peer: String) throws -> PendingContactOperation? {
        try check()
        return try db.read { db in
            guard let row = try ContactOperationRecord.fetchOne(db, key: peer) else { return nil }
            guard let action = ContactAction(rawValue: row.action) else { throw ChatStoreError.unavailable }
            return .init(bytes: row.bytes, action: action, remark: row.remark, message: row.message)
        }
    }
    /// 保存指定联系人的首个未决请求；已有同字节请求时不重复保存，不同字节请求被拒绝。
    public func saveContactOperation(_ value: PendingContactOperation, peer: String) throws {
        try check()
        try db.write { db in
            // 一个联系人只允许一个待确认操作，不覆盖不确定请求的原始字节。
            if let old = try ContactOperationRecord.fetchOne(db, key: peer) {
                guard old.bytes == value.bytes else { throw ChatStoreError.unavailable }; return
            }
            try ContactOperationRecord(peerID: peer, bytes: value.bytes, action: value.action.rawValue,
                remark: value.remark, message: value.message).insert(db)
        }
    }
    /// 移除指定联系人的未决请求记录；不存在时不产生其他修改。
    public func removeContactOperation(peer: String) throws {
        try check(); _ = try db.write { try ContactOperationRecord.deleteOne($0, key: peer) }
    }
}
