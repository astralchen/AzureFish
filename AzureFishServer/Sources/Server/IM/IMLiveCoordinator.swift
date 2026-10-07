import Fluent
import Foundation
import Vapor

/// 收集当前写事务影响的账号；仅在事务成功返回后发布。
final class IMCommitSignals: @unchecked Sendable {
    @TaskLocal static var current: IMCommitSignals?
    private let lock = NSLock()
    private var users: Set<UUID> = []
    func insert(_ values: [UUID]) { lock.lock(); defer { lock.unlock() }; users.formUnion(values) }
    var affected: Set<UUID> { lock.lock(); defer { lock.unlock() }; return users }
}

/// 同账号连接共享补偿检查；数据库访问保留原账号事务锁和每秒鉴权频率。
actor IMLiveCoordinator {
    private struct Client: Sendable {
        let id: UUID
        let session: UUID
        let credential: String
        let request: Request
        let socket: WebSocket
        var previous: Data?
        var sentAt: Date = .distantPast
    }
    private struct Entry {
        let id: UUID
        var clients: [UUID: Client]
        let wake: AsyncStream<Void>.Continuation
        let worker: Task<Void, Never>
        let timer: Task<Void, Never>
    }
    private let accounts: AccountService
    private let epoch: String
    private var entries: [UUID: Entry] = [:]
    private var queryBatches = 0
    /// 不含账号标识的诊断计数，供固定负载验证共享查询与连接回收。
    func diagnostics() -> (accounts: Int, connections: Int, queryBatches: Int) {
        (entries.count, entries.values.reduce(0) { $0 + $1.clients.count }, queryBatches)
    }
    init(accounts: AccountService, epoch: String) { self.accounts = accounts; self.epoch = epoch }

    func subscribe(_ request: Request, socket: WebSocket, session: SessionRecord) throws -> UUID {
        let sessionID = try session.requireID(), user = session.userID
        let clients = entries.values.flatMap { $0.clients.values }
        guard clients.count < 128, clients.filter({ $0.session == sessionID }).count < 4 else {
            throw APIError(.tooManyRequests, "CONNECTION_LIMIT")
        }
        let id = UUID()
        let credential = accounts.crypto.digest(Data((request.headers.bearerAuthorization?.token ?? "").utf8), purpose: "live-credential")
        let client = Client(id: id, session: sessionID, credential: credential, request: request, socket: socket)
        if var entry = entries[user] {
            entry.clients[id] = client; entries[user] = entry; entry.wake.yield(())
        } else {
            let (stream, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let entryID = UUID()
            let worker = Task { [weak self] in
                for await _ in stream {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                    guard !Task.isCancelled else { break }
                    await self?.tick(user, entryID: entryID)
                }
            }
            let timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    await self?.wake(user)
                }
            }
            entries[user] = Entry(id: entryID, clients: [id: client], wake: wake, worker: worker, timer: timer)
            wake.yield(())
        }
        return id
    }
    private func wake(_ user: UUID) { entries[user]?.wake.yield(()) }
    func changed(_ users: Set<UUID>? = nil) {
        for user in users ?? Set(entries.keys) { wake(user) }
    }
    func unsubscribe(user: UUID, id: UUID) {
        guard var entry = entries[user] else { return }
        entry.clients[id] = nil
        if entry.clients.isEmpty {
            entries[user] = nil
            entry.wake.finish(); entry.worker.cancel(); entry.timer.cancel()
        } else { entries[user] = entry }
    }
    private func tick(_ user: UUID, entryID: UUID) async {
        guard let entry = entries[user], entry.id == entryID else { return }
        let clients = Array(entry.clients.values), accounts = accounts, epoch = epoch
        do {
            let (bytes, invalid) = try await accounts.gate.run {
                var invalid = Set<String>()
                let credentials = Dictionary(grouping: clients, by: \.credential)
                for (credential, clients) in credentials {
                    do { _ = try await accounts.authenticate(clients[0].request, db: clients[0].request.db) }
                    catch { invalid.insert(credential) }
                }
                let db = clients[0].request.db
                let messageTail = try await IMEventRecord.query(on: db).filter(\.$userID == user).sort(\.$position, .descending).first()?.position ?? 0
                let contactTail = try await ContactEventRecord.query(on: db).filter(\.$userID == user).sort(\.$position, .descending).first()?.position ?? 0
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(IMCursor(user: user, resource: "events", epoch: epoch, position: max(messageTail, contactTail)))
                var hint = IMSyncHint(); hint.epoch = epoch
                hint.latestCursor = data.base64EncodedString() + "." + accounts.crypto.digest(data, purpose: "im-cursor")
                hint.ownProfileVersion = try await UserRecord.find(user, on: db)?.version ?? 0
                return (try hint.serializedData(), invalid)
            }
            queryBatches += 1
            for client in clients {
                guard entries[user]?.id == entryID, var current = entries[user]?.clients[client.id] else { continue }
                if invalid.contains(client.credential) {
                    unsubscribe(user: user, id: client.id)
                    try? await client.socket.close(code: .policyViolation)
                } else if current.previous != bytes || Date().timeIntervalSince(current.sentAt) >= 25 {
                    do {
                        try await client.socket.send(raw: bytes, opcode: .binary)
                        current.previous = bytes; current.sentAt = Date()
                        if entries[user]?.id == entryID, entries[user]?.clients[client.id] != nil {
                            entries[user]?.clients[client.id] = current
                        }
                    } catch { unsubscribe(user: user, id: client.id) }
                }
            }
        } catch {
            for client in clients {
                unsubscribe(user: user, id: client.id)
                try? await client.socket.close(code: .policyViolation)
            }
        }
    }
    deinit {
        for entry in entries.values { entry.worker.cancel(); entry.timer.cancel(); entry.wake.finish() }
    }
}
