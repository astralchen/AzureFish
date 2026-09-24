import Foundation
import Server
import Vapor

@main
enum EntryPoint {
    enum StartupError: Error { case failed }
    static func main() async throws {
        // 首期可执行程序只提供固定的回环监听，不接受 CLI 参数放宽网络边界。
        guard CommandLine.arguments.count == 1 else {
            print("AzureFishServer accepts configuration through environment variables only.")
            return
        }
        let app = try await Application.make(Environment(name: "development", arguments: ["AzureFishServer", "serve"]))
        do {
            try await configure(app, configuration: .local())
            try await app.execute()
        } catch {
            app.logger.error("Server failed to start or run; check configuration, key permissions and database ownership.")
            try await app.asyncShutdown()
            throw StartupError.failed
        }
        try await app.asyncShutdown()
    }
}
