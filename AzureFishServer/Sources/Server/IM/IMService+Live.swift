import Foundation
import Fluent
import Vapor

extension IMService {
    func registerLive(on routes: any RoutesBuilder) {
        routes.get("live") { req async throws -> Response in
            // 在普通 HTTP 路由中鉴权，握手失败仍返回统一 Protobuf 错误。
            _ = try await self.accounts.gate.run { try await self.accounts.authenticate(req, db: req.db).requireID() }
            return req.webSocket(maxFrameSize: 1024) { req, socket async in
                do {
                    let session = try await self.accounts.gate.run { try await self.accounts.authenticate(req, db: req.db) }
                    let id = try await self.live.subscribe(req, socket: socket, session: session)
                    let user = session.userID
                    socket.onClose.whenComplete { _ in Task { await self.live.unsubscribe(user: user, id: id) } }
                } catch { try? await socket.close(code: .policyViolation); return }
                // WebSocketKit 的同步回调槽是 NIOLoopBound，必须在所属 event loop 注册。
                socket.eventLoop.execute {
                    socket.onText { socket, _ in socket.close(code: .policyViolation, promise: nil) }
                    socket.onBinary { socket, _ in socket.close(code: .policyViolation, promise: nil) }
                }
            }
        }
    }
}
