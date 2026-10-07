import AzureFishChat
import AzureFishStorage
import Foundation

/// 当前安装中的账号业务资源所有者；多窗口及未来业务借用同一实例。
@MainActor
final class AccountBusinessStorage {
    struct Resources: Sendable {
        let database: AccountDatabase
        let media: EncryptedMediaStore
    }
    private struct Entry {
        let resources: Resources
        var borrowers: Set<UUID>
    }
    private static var entries: [String: Entry] = [:]
    private struct Opening {
        let id: UUID
        let task: Task<Resources, Error>
    }
    private static var openings: [String: Opening] = [:]
    private static var reservations: [UUID: Set<UUID>] = [:]
    private static var closings: [String: Task<Void, Error>] = [:]

    let resources: Resources
    private let scope: String
    private let borrower: UUID
    private var released = false
    private var releasing: Task<Void, Error>?
    private init(resources: Resources, scope: String, borrower: UUID) {
        self.resources = resources; self.scope = scope; self.borrower = borrower
    }

    /// 等待同一账号正在进行的打开或关闭，之后才检查目录完整性。
    static func waitForOpening(environment: String, userID: UUID) async throws {
        let scope = environment + ":" + userID.uuidString.lowercased()
        if let closing = closings[scope] { try await closing.value }
        if let opening = openings[scope] { _ = try await opening.task.value }
    }

    /// 复用环境及账号范围内的数据库和媒体实例；新实例在后台验证密钥与基线。
    static func acquire(root: URL, databaseKey: Data, mediaKey: Data, environment: String, userID: UUID) async throws -> AccountBusinessStorage {
        let scope = environment + ":" + userID.uuidString.lowercased()
        if let closing = closings[scope] { try await closing.value }
        let borrower = UUID()
        let resources: Resources
        var reserved: Set<UUID> = []
        if let entry = entries[scope] { resources = entry.resources }
        else {
            let opening: Opening
            if let pending = openings[scope] { opening = pending }
            else {
                let task = Task.detached {
                    let database = try ChatStore.openDatabase(url: root.appendingPathComponent("main.sqlite"),
                        key: databaseKey, environment: environment, userID: userID)
                    do {
                        let media = try EncryptedMediaStore(root: root.appendingPathComponent("media"), key: mediaKey,
                            environment: environment, userID: userID)
                        let chat = try ChatStore(database: database)
                        try await chat.recoverMediaImports(using: ChatMediaStore(storage: media))
                        try await chat.close()
                        let oldPages = root.appendingPathComponent("page-leases")
                        if FileManager.default.fileExists(atPath: oldPages.path) { try FileManager.default.removeItem(at: oldPages) }
                        return Resources(database: database, media: media)
                    } catch { try? database.close(); throw error }
                }
                opening = Opening(id: UUID(), task: task)
                openings[scope] = opening
            }
            reservations[opening.id, default: []].insert(borrower)
            do { resources = try await opening.task.value }
            catch {
                if openings[scope]?.id == opening.id { openings[scope] = nil }
                reservations[opening.id]?.remove(borrower)
                if reservations[opening.id]?.isEmpty == true { reservations[opening.id] = nil }
                throw error
            }
            if openings[scope]?.id == opening.id { openings[scope] = nil }
            reserved = reservations.removeValue(forKey: opening.id) ?? []
        }
        var entry = entries[scope] ?? Entry(resources: resources, borrowers: [])
        entry.borrowers.formUnion(reserved)
        entry.borrowers.insert(borrower); entries[scope] = entry
        return .init(resources: resources, scope: scope, borrower: borrower)
    }

    /// 当前业务停止全部任务后释放借用；最后一个借用者离开时才关闭账号资源。
    func release() async throws {
        if let releasing { try await releasing.value; return }
        guard !released, var entry = Self.entries[scope] else { return }
        let originalEntry = entry
        entry.borrowers.remove(borrower)
        if !entry.borrowers.isEmpty {
            Self.entries[scope] = entry; released = true; return
        }
        let resources = resources, scope = scope
        Self.entries[scope] = nil
        let closing = Task { @MainActor in
            do {
                try await resources.media.clearLeases()
                try resources.database.close()
                Self.closings[scope] = nil
            } catch {
                Self.entries[scope] = originalEntry
                Self.closings[scope] = nil
                throw error
            }
        }
        releasing = closing; Self.closings[scope] = closing
        do { try await closing.value; released = true; releasing = nil }
        catch { releasing = nil; throw error }
    }
}
