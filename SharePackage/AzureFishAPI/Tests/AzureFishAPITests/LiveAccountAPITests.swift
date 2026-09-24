#if DEBUG && os(macOS)
import AzureFishAPI
import Foundation
import Testing

@Suite("本机 AzureFishServer 联调")
struct LiveAccountAPITests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AZUREFISH_API_LIVE_TEST"] == "1", "只在显式启用并启动虚构数据服务时运行"))
    func completeAccountFlow() async throws {
        let api = AccountAPI(environment: try .localTesting())
        #expect(try await api.health().status == "ok")
        let name = "spm_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        let device = UUID()
        let registration = try api.prepareRegistration(operationID: UUID(), deviceID: device, accountName: name,
            password: "Fictional-SPM-Password-123", nickname: "本地包联调")
        let registered = try await api.execute(registration)
        #expect(try await api.execute(registration) == registered)
        let login = try api.prepareLogin(operationID: UUID(), deviceID: device, accountName: name, password: "Fictional-SPM-Password-123")
        let loggedIn = try await api.execute(login)
        #expect(loggedIn.profile.userID == registered.profile.userID)
        let edit = try api.prepareProfileUpdate(operationID: UUID(), changes: .init(expectedVersion: 1, bio: "繁體 العربية English 简体"), using: loggedIn.credentials)
        let edited = try await api.execute(edit, using: loggedIn.credentials)
        #expect(edited.version == 2)
        let refresh = try api.prepareRefresh(operationID: UUID(), using: loggedIn.credentials)
        let renewed = try await api.execute(refresh)
        #expect(try await api.execute(refresh) == renewed)
        #expect(try await api.execute(edit, using: renewed.credentials) == edited)
        #expect(try await api.profile(using: renewed.credentials).bio == edited.bio)
        let logout = try api.prepareLogout(operationID: UUID(), using: renewed.credentials)
        _ = try await api.execute(logout, using: renewed.credentials)
        _ = try await api.execute(logout, using: renewed.credentials)
        do { _ = try await api.profile(using: renewed.credentials); Issue.record("Logged-out session remained usable") }
        catch APIClientError.service(let failure) { #expect(failure.isUnauthenticated) }
        _ = try await api.execute(api.prepareLogout(operationID: UUID(), using: registered.credentials), using: registered.credentials)
    }
}
#endif
