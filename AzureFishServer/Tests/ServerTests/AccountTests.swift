@testable import Server
import Crypto
import Fluent
import Foundation
import SwiftProtobuf
import Testing
import VaporTesting

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

struct Fixture: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("azurefish-test-" + UUID().uuidString).path
    let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    let clock = TestClock()
    func app(key override: Data? = nil) async throws -> Application {
        let app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        do {
            try await configure(app, configuration: .init(directory: directory, key: override ?? key, environmentID: "test", bcryptCost: 4, clock: { clock.now() }))
            return app
        } catch {
            try await app.asyncShutdown()
            throw error
        }
    }
    func clean() { try? FileManager.default.removeItem(atPath: directory) }
}

func withServer(_ body: (Application, Fixture) async throws -> Void) async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    let app = try await fixture.app()
    do { try await body(app, fixture) }
    catch { try await app.asyncShutdown(); throw error }
    try await app.asyncShutdown()
}

func registration(_ name: String = "test_account") -> RegisterRequest {
    var request = RegisterRequest()
    request.operationID = UUID().uuidString; request.deviceID = UUID().uuidString
    request.accountName = name; request.password = "Fictional-Test-Password-123"; request.nickname = "虚构测试昵称"
    return request
}

func send<M: Message>(_ app: Application, _ method: HTTPMethod, _ path: String, _ message: M, token: String? = nil) async throws -> TestingHTTPResponse {
    var headers: HTTPHeaders = ["Content-Type": "application/protobuf", "Accept": "application/protobuf"]
    if let token { headers.bearerAuthorization = .init(token: token) }
    return try await app.testing().sendRequest(method, path, headers: headers, body: ByteBuffer(bytes: try message.serializedData()))
}
func decode<M: Message>(_ type: M.Type, _ response: TestingHTTPResponse) throws -> M {
    try M(serializedBytes: Data(response.body.readableBytesView))
}
func auth(_ app: Application, name: String = "test_account") async throws -> AuthResponse {
    let response = try await send(app, .POST, "/v1/auth/register", registration(name))
    #expect(response.status == .created)
    return try decode(AuthResponse.self, response)
}
func refresh(_ token: String) -> RefreshRequest {
    var request = RefreshRequest(); request.operationID = UUID().uuidString; request.refreshToken = token
    return request
}
func me(_ app: Application, _ token: String) async throws -> TestingHTTPResponse {
    try await app.testing().sendRequest(.GET, "/v1/me", headers: ["Authorization": "Bearer " + token])
}
func errorCode(_ response: TestingHTTPResponse) throws -> String { try decode(ApiError.self, response).code }

@Suite("账号接口", .serialized)
struct AccountTests {
    @Test func registerLoginProfileLogout() async throws {
        try await withServer { (app: Application, _: Fixture) async throws in
            let input = registration("  Alice_TEST  ")
            let result = try await send(app, .POST, "/v1/auth/register", input)
            let first = try decode(AuthResponse.self, result)
            #expect(first.profile.accountName == "alice_test")
            #expect(first.profile.profileVersion == 1)
            #expect(first.environmentID == "test")
            #expect(first.accessToken != first.refreshToken)
            #expect(result.headers.first(name: "Cache-Control") == "no-store")
            #expect(result.headers.first(name: "X-Request-ID") != nil)
            let repeated = try await send(app, .POST, "/v1/auth/register", input)
            #expect(repeated.body == result.body)
            var login = LoginRequest()
            login.operationID = UUID().uuidString; login.deviceID = input.deviceID
            login.accountName = "ALICE_TEST"; login.password = input.password
            let loggedIn = try decode(AuthResponse.self, await send(app, .POST, "/v1/auth/login", login))
            #expect(loggedIn.userID == first.userID)
            #expect(loggedIn.sessionID != first.sessionID)
            let loginAgain = try decode(AuthResponse.self, await send(app, .POST, "/v1/auth/login", login))
            #expect(loginAgain.accessToken == loggedIn.accessToken)
            #expect(try await me(app, loggedIn.accessToken).status == .ok)
            var logout = LogoutRequest(); logout.operationID = UUID().uuidString
            #expect(try await send(app, .POST, "/v1/auth/logout", logout, token: loggedIn.accessToken).status == .ok)
            #expect(try await send(app, .POST, "/v1/auth/logout", logout, token: loggedIn.accessToken).status == .ok)
            #expect(try await me(app, loggedIn.accessToken).status == .unauthorized)
            #expect(try await send(app, .POST, "/v1/auth/refresh", refresh(loggedIn.refreshToken)).status == .unauthorized)
            #expect(try await me(app, first.accessToken).status == .ok)
        }
    }

    @Test func refreshRecoverySupersessionAndReplayRevocation() async throws {
        try await withServer { (app: Application, _: Fixture) async throws in
            let first = try await auth(app)
            let request = refresh(first.refreshToken)
            let result = try await send(app, .POST, "/v1/auth/refresh", request)
            let second = try decode(AuthResponse.self, result)
            #expect(second.refreshGeneration == 2)
            #expect(second.refreshExpiresAtMs == first.refreshExpiresAtMs)
            #expect(try await send(app, .POST, "/v1/auth/refresh", request).body == result.body)
            #expect(try await me(app, first.accessToken).status == .unauthorized)
            let thirdResult = try await send(app, .POST, "/v1/auth/refresh", refresh(second.refreshToken))
            let third = try decode(AuthResponse.self, thirdResult)
            let stale = try await send(app, .POST, "/v1/auth/refresh", request)
            #expect(try errorCode(stale) == "REFRESH_SUPERSEDED")
            #expect(try await me(app, third.accessToken).status == .ok)
            let replay = try await send(app, .POST, "/v1/auth/refresh", refresh(first.refreshToken))
            #expect(try errorCode(replay) == "REFRESH_REPLAY")
            #expect(try await me(app, third.accessToken).status == .unauthorized)
            #expect(try await send(app, .POST, "/v1/auth/refresh", refresh(third.refreshToken)).status == .unauthorized)
        }
    }

    @Test func concurrentDuplicateRefreshIssuesOneGeneration() async throws {
        try await withServer { (app: Application, _: Fixture) async throws in
            let first = try await auth(app)
            let request = refresh(first.refreshToken)
            async let a = send(app, .POST, "/v1/auth/refresh", request)
            async let b = send(app, .POST, "/v1/auth/refresh", request)
            let (one, two) = try await (a, b)
            #expect(one.status == .ok && two.status == .ok)
            #expect(one.body == two.body)
            #expect(try await UsedRefreshRecord.query(on: app.db).count() == 1)
        }
    }

    @Test func concurrentRegistrationCreatesOneAccount() async throws {
        try await withServer { (app: Application, _: Fixture) async throws in
            let input = registration()
            async let a = send(app, .POST, "/v1/auth/register", input)
            async let b = send(app, .POST, "/v1/auth/register", input)
            let (one, two) = try await (a, b)
            #expect(one.status == .created && two.status == .created)
            #expect(one.body == two.body)
            #expect(try await UserRecord.query(on: app.db).count() == 1)
            #expect(try await SessionRecord.query(on: app.db).count() == 1)
        }
    }

    @Test func profileRetrySurvivesTokenRotation() async throws {
        try await withServer { (app: Application, _: Fixture) async throws in
            let first = try await auth(app)
            var patch = UpdateProfileRequest()
            patch.operationID = UUID().uuidString; patch.expectedProfileVersion = 1; patch.nickname = "繁體中文測試"
            let saved = try await send(app, .PATCH, "/v1/me", patch, token: first.accessToken)
            let renewed = try decode(AuthResponse.self, await send(app, .POST, "/v1/auth/refresh", refresh(first.refreshToken)))
            let retried = try await send(app, .PATCH, "/v1/me", patch, token: renewed.accessToken)
            #expect(retried.status == .ok && retried.body == saved.body)
            #expect(try decode(UserProfile.self, await me(app, renewed.accessToken)).profileVersion == 2)
        }
    }

    @Test func expiredRefreshRecoveryNeverExecutesAgain() async throws {
        try await withServer { (app: Application, fixture: Fixture) async throws in
            let first = try await auth(app)
            let request = refresh(first.refreshToken)
            let second = try decode(AuthResponse.self, await send(app, .POST, "/v1/auth/refresh", request))
            fixture.clock.advance(601)
            #expect(try errorCode(await send(app, .POST, "/v1/auth/refresh", request)) == "AUTH_ATTEMPT_EXPIRED")
            #expect(try await me(app, second.accessToken).status == .ok)
            #expect(try await SessionRecord.query(on: app.db).first()?.generation == 2)
        }
    }

    @Test func secondProcessLeaseAndCipherTampering() async throws {
        try await withServer { (app: Application, fixture: Fixture) async throws in
            _ = try await auth(app)
            do {
                let duplicate = try await fixture.app()
                try await duplicate.asyncShutdown()
                Issue.record("Second owner unexpectedly opened the database")
            } catch {}
            let user = try #require(await UserRecord.query(on: app.db).first())
            var corrupted = try #require(Data(base64Encoded: user.payload))
            corrupted[corrupted.count - 1] ^= 1
            let crypto = try Cryptography(key: fixture.key, environment: "test")
            #expect(throws: (any Error).self) {
                try crypto.open(corrupted.base64EncodedString(), context: "user:" + user.requireID().uuidString)
            }
        }
    }

    @Test func profilePresenceConflictsAndIsolation() async throws {
        try await withServer { (app: Application, _: Fixture) async throws in
            let a = try await auth(app, name: "account_a"), b = try await auth(app, name: "account_b")
            var patch = UpdateProfileRequest()
            patch.operationID = UUID().uuidString; patch.expectedProfileVersion = 1; patch.bio = "简介 العربية"
            let saved = try await send(app, .PATCH, "/v1/me", patch, token: a.accessToken)
            let profile = try decode(UserProfile.self, saved)
            #expect(profile.profileVersion == 2 && profile.bio == patch.bio)
            #expect(profile.nickname == a.profile.nickname)
            #expect(try await send(app, .PATCH, "/v1/me", patch, token: a.accessToken).body == saved.body)
            #expect(try errorCode(await send(app, .PATCH, "/v1/me", patch, token: b.accessToken)) == "OPERATION_CONFLICT")
            patch.operationID = UUID().uuidString
            #expect(try errorCode(await send(app, .PATCH, "/v1/me", patch, token: a.accessToken)) == "PROFILE_VERSION_CONFLICT")
            patch.operationID = UUID().uuidString; patch.expectedProfileVersion = 2; patch.bio = ""
            #expect(try decode(UserProfile.self, await send(app, .PATCH, "/v1/me", patch, token: a.accessToken)).bio == "")
            let other = try decode(UserProfile.self, await me(app, b.accessToken))
            #expect(other.profileVersion == 1 && other.bio == "")
        }
    }

    @Test func credentialsAndOperationConflict() async throws {
        try await withServer { (app: Application, _: Fixture) async throws in
            var input = registration()
            #expect(try await send(app, .POST, "/v1/auth/register", input).status == .created)
            input.nickname = "另一个昵称"
            #expect(try errorCode(await send(app, .POST, "/v1/auth/register", input)) == "OPERATION_CONFLICT")
            input.operationID = UUID().uuidString
            #expect(try errorCode(await send(app, .POST, "/v1/auth/register", input)) == "ACCOUNT_TAKEN")
            var login = LoginRequest()
            login.operationID = UUID().uuidString; login.deviceID = UUID().uuidString
            login.accountName = input.accountName; login.password = "Incorrect-Password-123"
            #expect(try errorCode(await send(app, .POST, "/v1/auth/login", login)) == "INVALID_CREDENTIALS")
            login.accountName = "unknown_account"
            #expect(try errorCode(await send(app, .POST, "/v1/auth/login", login)) == "INVALID_CREDENTIALS")
        }
    }

    @Test func expiryAndRecoveryWindow() async throws {
        try await withServer { (app: Application, fixture: Fixture) async throws in
            let request = registration()
            let result = try decode(AuthResponse.self, await send(app, .POST, "/v1/auth/register", request))
            fixture.clock.advance(601)
            #expect(try errorCode(await send(app, .POST, "/v1/auth/register", request)) == "AUTH_ATTEMPT_EXPIRED")
            fixture.clock.advance(300)
            #expect(try await me(app, result.accessToken).status == .unauthorized)
            let renewed = try decode(AuthResponse.self, await send(app, .POST, "/v1/auth/refresh", refresh(result.refreshToken)))
            #expect(renewed.refreshExpiresAtMs == result.refreshExpiresAtMs)
            fixture.clock.advance(30 * 24 * 60 * 60)
            #expect(try await send(app, .POST, "/v1/auth/refresh", refresh(renewed.refreshToken)).status == .unauthorized)
        }
    }

    @Test func protocolErrorsAndBodyLimit() async throws {
        try await withServer { (app: Application, _: Fixture) async throws in
            let wrongMIME = try await app.testing().sendRequest(.POST, "/v1/auth/register", headers: ["Content-Type": "application/json"], body: ByteBuffer(string: "{}"))
            #expect(wrongMIME.status == .unsupportedMediaType)
            #expect(wrongMIME.headers.first(name: "Content-Type") == "application/protobuf")
            let malformed = try await app.testing().sendRequest(.POST, "/v1/auth/register", headers: ["Content-Type": "application/protobuf"], body: ByteBuffer(bytes: [255]))
            #expect(try errorCode(malformed) == "MALFORMED_PROTOBUF")
            #expect(try await app.testing().sendRequest(.GET, "/health", headers: ["Accept": "application/json"]).status == .notAcceptable)
            #expect(try await app.testing().sendRequest(.GET, "/health", headers: ["Accept": ";"]).status == .notAcceptable)
            #expect(try await app.testing().sendRequest(.GET, "/does-not-exist").status == .notFound)
            let tooLarge = try await app.testing().sendRequest(.POST, "/v1/auth/register", headers: ["Content-Type": "application/protobuf"], body: ByteBuffer(repeating: 65, count: 20_000))
            #expect(tooLarge.status == .payloadTooLarge)
            #expect(try await app.testing().sendRequest(.GET, "/v1/me").status == .unauthorized)
        }
    }

    @Test func validationAndAccountRateLimit() async throws {
        try await withServer { (app: Application, _: Fixture) async throws in
            var input = registration()
            input.password = String(repeating: "中", count: 25)
            #expect(try errorCode(await send(app, .POST, "/v1/auth/register", input)) == "VALIDATION_FAILED")
            input = registration(); input.nickname = " \n "
            #expect(try errorCode(await send(app, .POST, "/v1/auth/register", input)) == "VALIDATION_FAILED")
            var login = LoginRequest()
            login.deviceID = UUID().uuidString; login.accountName = "missing"; login.password = "Incorrect-Password-123"
            for _ in 0..<10 {
                login.operationID = UUID().uuidString
                #expect(try await send(app, .POST, "/v1/auth/login", login).status == .unauthorized)
            }
            login.operationID = UUID().uuidString
            let limited = try await send(app, .POST, "/v1/auth/login", login)
            #expect(limited.status == .tooManyRequests)
            #expect(limited.headers.first(name: "Retry-After") == "60")
        }
    }

    @Test func restartPreservesSessionAndRefreshRecovery() async throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let first = try await fixture.app()
        let session: AuthResponse
        let request: RefreshRequest
        let refreshed: AuthResponse
        do {
            session = try await auth(first)
            request = refresh(session.refreshToken)
            refreshed = try decode(AuthResponse.self, await send(first, .POST, "/v1/auth/refresh", request))
        } catch { try await first.asyncShutdown(); throw error }
        try await first.asyncShutdown()
        let second = try await fixture.app()
        do {
            #expect(try await me(second, refreshed.accessToken).status == .ok)
            let recovered = try decode(AuthResponse.self, await send(second, .POST, "/v1/auth/refresh", request))
            #expect(recovered == refreshed)
        } catch { try await second.asyncShutdown(); throw error }
        try await second.asyncShutdown()
    }

    @Test func atRestEncryptionAndWrongKey() async throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let app = try await fixture.app()
        let session: AuthResponse
        do {
            session = try await auth(app)
            let user = try #require(await UserRecord.query(on: app.db).first())
            let crypto = try Cryptography(key: fixture.key, environment: "test")
            #expect(throws: (any Error).self) { try crypto.open(user.payload, context: "user:" + UUID().uuidString) }
            for name in try FileManager.default.contentsOfDirectory(atPath: fixture.directory) where name.hasPrefix("server.sqlite") {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: fixture.directory + "/" + name))
                for secret in ["test_account", "虚构测试昵称", "Fictional-Test-Password-123", session.accessToken, session.refreshToken] {
                    #expect(bytes.range(of: Data(secret.utf8)) == nil)
                }
            }
        } catch { try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
        do {
            let wrong = try await fixture.app(key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
            try await wrong.asyncShutdown()
            Issue.record("Wrong key unexpectedly opened database")
        } catch {}
        let reopened = try await fixture.app()
        #expect(try await me(reopened, session.accessToken).status == .ok)
        try await reopened.asyncShutdown()
    }
}
