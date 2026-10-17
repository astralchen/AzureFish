import Foundation

/// 可注入的受保护数据存储。写入替换整个值，失败时不删除原项。
@MainActor
protocol SecureValueStoring {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
    func remove(_ key: String) throws
}
