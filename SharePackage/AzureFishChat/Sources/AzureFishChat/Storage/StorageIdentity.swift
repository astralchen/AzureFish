import Foundation

/// 数据库存储身份损坏时停止读取，避免生成新的业务身份。
func storageUUID(_ value: String?) throws -> UUID {
    guard let value, let id = UUID(uuidString: value) else { throw ChatStoreError.unavailable }
    return id
}
