import Foundation
import Fluent
import Vapor

/// 控制本机实时提示连接数量；HTTP 增量始终是消息恢复的权威来源。
actor IMLiveConnections {
    private var sessions: [UUID: Int] = [:]
    func acquire(_ session: UUID) throws {
        guard sessions.values.reduce(0, +) < 128, sessions[session, default: 0] < 4 else { throw APIError(.tooManyRequests, "CONNECTION_LIMIT") }
        sessions[session, default: 0] += 1
    }
    func release(_ session: UUID) {
        let count = sessions[session, default: 0] - 1
        if count <= 0 { sessions.removeValue(forKey: session) } else { sessions[session] = count }
    }
}

extension IMService {
    func registerLive(on routes: any RoutesBuilder) {
        let connections = IMLiveConnections()
        routes.get("live") { req async throws -> Response in
            // 在普通 HTTP 路由中鉴权，握手失败仍返回统一 Protobuf 错误。
            _ = try await self.accounts.gate.run { try await self.accounts.authenticate(req, db: req.db).requireID() }
            return req.webSocket(maxFrameSize: 1024) { req, socket async in
                let sessionID: UUID
                do {
                    sessionID = try await self.accounts.gate.run { try await self.accounts.authenticate(req, db: req.db).requireID() }
                    try await connections.acquire(sessionID)
                } catch { try? await socket.close(code: .policyViolation); return }
                let task = Task {
                    do {
                        var previous = ""
                        var previousProfile: Int64 = 0
                        var ticks = 0
                        while !Task.isCancelled && !socket.isClosed {
                            let hint = try await self.accounts.gate.run {
                                let session = try await self.accounts.authenticate(req, db: req.db)
                                let tail = try await self.tail(session.userID, db: req.db)
                                var hint = IMSyncHint(); hint.epoch = self.epoch
                                hint.latestCursor = try self.cursor(user: session.userID, resource: "events", position: tail)
                                hint.ownProfileVersion = try await UserRecord.find(session.userID, on: req.db)?.version ?? 0
                                return hint
                            }
                            if previous != hint.latestCursor || previousProfile != hint.ownProfileVersion || ticks % 25 == 0 {
                                try await socket.send(raw: hint.serializedData(), opcode: .binary)
                                previous = hint.latestCursor
                                previousProfile = hint.ownProfileVersion
                            }
                            ticks += 1
                            try await Task.sleep(for: .seconds(1))
                        }
                    } catch { try? await socket.close(code: .policyViolation) }
                    await connections.release(sessionID)
                }
                socket.onClose.whenComplete { _ in task.cancel() }
                // WebSocketKit 的同步回调槽是 NIOLoopBound，必须在所属 event loop 注册。
                socket.eventLoop.execute {
                    socket.onText { socket, _ in socket.close(code: .policyViolation, promise: nil) }
                    socket.onBinary { socket, _ in socket.close(code: .policyViolation, promise: nil) }
                }
            }
        }
    }
}
