@testable import Server
import Fluent
import Foundation
import Darwin
import Testing
import VaporTesting

// 与优化前的读取算法保持一致，仅用于固定负载对照。
private extension IMService {
    func baselineView(_ row: IMConversationRecord, _ state: IMConversationState, user: UUID, db: any Database) async throws -> IMConversation {
        guard let member = state.members.first(where: { $0.user == user }) else { throw APIError(.notFound, "CONVERSATION_NOT_FOUND") }
        var result = IMConversation()
        result.conversationID = try row.requireID().uuidString.lowercased(); result.kind = state.kind; result.title = state.title
        result.ownerUserID = state.owner?.uuidString.lowercased() ?? ""
        result.serverRevision = state.revision; result.boundaryRevision = state.boundary
        result.latestSeq = member.upperBound(state.latest); result.closed = !member.active || state.dissolved
        for value in state.members {
            var m = IMMember(); m.userID = value.user.uuidString.lowercased(); m.active = value.active
            m.intervals = value.intervals.map { interval in
                var i = IMMembershipInterval(); i.joinedSeq = interval.joined; i.leftSeq = interval.left; return i
            }
            if let userRow = try await UserRecord.find(value.user, on: db) {
                m.profile.userID = m.userID; m.profile.nickname = try accounts.payload(userRow).nickname
                m.profile.profileVersion = userRow.version
                m.profile.avatarID = try accounts.payload(userRow).avatarID ?? ""
                m.profile.deleted = try accounts.payload(userRow).deleted == true
            }
            result.members.append(m)
        }
        var read = IMReadState(); read.readThroughSeq = member.read; read.deliveredThroughSeq = member.delivered
        read.summaryAtSeq = result.latestSeq; read.serverRevision = state.summaryRevision
        // 单实例开发版按受众检查，不能用最高序号减阅读水位替代未读计数。
        let rows = try await IMMessageRecord.query(on: db).filter(\.$conversationID == row.requireID())
            .filter(\.$sequence > member.read).filter(\.$sequence <= result.latestSeq).all()
        for message in rows where member.sees(message.sequence) {
            let value = try storedMessage(message)
            if !value.revoked && value.senderUserID != user.uuidString.lowercased() { read.unreadCount += 1 }
        }
        for interval in member.intervals.reversed() {
            let upper = min(result.latestSeq, interval.left == 0 ? result.latestSeq : interval.left - 1)
            if let latest = try await IMMessageRecord.query(on: db)
                .filter(\.$conversationID == row.requireID()).filter(\.$sequence >= interval.joined)
                .filter(\.$sequence <= upper).sort(\.$sequence, .descending).first() {
                result.latestMessage = try renderedMessage(latest, state)
                break
            }
        }
        if let frozen = member.closedConversation {
            result = try IMConversation(serializedBytes: frozen)
        }
        result.readState = read; return result
    }
}

@Suite("IM 固定负载读取", .serialized)
struct IMReadPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AZUREFISH_RUN_READ_BENCHMARK"] == "1"))
    func projectedViewMatchesBaselineWithBoundedQueries() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "read_bench_a"), b = try await auth(app, name: "read_bench_b")
            let chat = try await direct(app, a, b)
            let service = try #require(app.storage[MediaServiceKey.self]).im
            let user = try #require(UUID(uuidString: b.userID))
            let sender = try #require(UUID(uuidString: a.userID))
            // 直接准备隔离密文负载，测量不包含 HTTP 限流或 350 次写请求。
            try await app.db.transaction { db in
                let (row, original) = try await service.load(chat.conversationID, user: user, db: db)
                var state = original
                for sequence in 2...351 {
                    let id = UUID()
                    var message = IMMessage()
                    message.messageUuid = id.uuidString.lowercased(); message.conversationID = chat.conversationID
                    message.clientMessageID = UUID().uuidString.lowercased(); message.serverMessageID = UUID().uuidString.lowercased()
                    message.senderUserID = sender.uuidString.lowercased(); message.deviceID = a.deviceID
                    message.serverSeq = Int64(sequence); message.serverCreatedAtMs = Int64(sequence)
                    message.serverRevision = 1; message.contentType = "text"; message.contentSchemaVersion = 1
                    message.text = "固定虚构负载"
                    let record = IMMessageRecord(); record.id = id; record.conversationID = try row.requireID()
                    record.sequence = Int64(sequence); record.clientKey = id.uuidString
                    record.payload = try service.encrypt(IMMessageState(envelope: message.serializedData(), audience: [user], fingerprint: "fixture"), context: "message:" + id.uuidString)
                    try await record.create(on: db)
                    state.latest = Int64(sequence); state.summaryRevision += 1
                    service.adjustUnread(message, state: &state, delta: 1)
                }
                try await service.save(row, state, db: db)
            }
            let (row, state) = try await service.load(chat.conversationID, user: user, db: app.db)
            let history = QueryHistory()
            let db = try #require(app.databases.database(logger: app.logger, on: app.eventLoopGroup.next(), history: history))
            let mode = ProcessInfo.processInfo.environment["AZUREFISH_READ_BENCHMARK_MODE"] ?? "compare"
            if mode == "compare" {
                let baseline = try await service.baselineView(row, state, user: user, db: db)
                let projected = try await service.view(row, state, user: user, db: db)
                #expect(baseline == projected)
            }
            let clock = ContinuousClock()
            history.queries = []
            let oldStart = clock.now
            if mode != "projected" {
                for _ in 0..<20 { _ = try await service.baselineView(row, state, user: user, db: db) }
            }
            let oldDuration = oldStart.duration(to: clock.now)
            let oldQueries = history.queries.count
            history.queries = []
            let newStart = clock.now
            if mode != "baseline" {
                for _ in 0..<20 { _ = try await service.view(row, state, user: user, db: db) }
            }
            let newDuration = newStart.duration(to: clock.now)
            let newQueries = history.queries.count
            #expect(oldQueries == (mode == "projected" ? 0 : 80))
            #expect(newQueries == (mode == "baseline" ? 0 : 40))
            var usage = rusage()
            #expect(getrusage(RUSAGE_SELF, &usage) == 0)
            let peakBytes = usage.ru_maxrss
            print("IM_READ_BENCHMARK mode=\(mode) peakProcessBytes=\(peakBytes) messages=351 members=2 repeats=20 baselineQueries=\(oldQueries) projectedQueries=\(newQueries) baselineDuration=\(oldDuration) projectedDuration=\(newDuration)")
        }
    }
}
