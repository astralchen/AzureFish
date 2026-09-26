import Crypto
import Fluent
import FluentSQLiteDriver
import Foundation
import Vapor
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 首期本机服务配置；密钥由外部文件注入，已有数据库不得静默重建密钥。
public struct ServerConfiguration: Sendable {
    let directory: String
    let key: Data
    let environmentID: String
    let bcryptCost: Int
    let clock: @Sendable () -> Date

    init(directory: String, key: Data, environmentID: String = "local-development", bcryptCost: Int = 12, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.key = key; self.environmentID = environmentID
        self.bcryptCost = bcryptCost; self.clock = clock
    }

    public static func local() throws -> ServerConfiguration {
        guard Environment.get("AZUREFISH_ALLOW_LOCAL_TEST_DATA") == "1",
              let directory = Environment.get("AZUREFISH_DATA_DIRECTORY"), directory.hasPrefix("/"),
              let keyPath = Environment.get("AZUREFISH_KEY_FILE"), keyPath.hasPrefix("/") else {
            throw ConfigurationError.missingConfiguration
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: keyPath)
        guard (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw ConfigurationError.invalidKey }
        let key = try Data(contentsOf: URL(fileURLWithPath: keyPath))
        guard key.count == 32 else { throw ConfigurationError.invalidKey }
        return ServerConfiguration(directory: directory, key: key)
    }
}

private final class DatabaseLease: @unchecked Sendable {
    let descriptor: Int32
    init(path: String) throws {
        descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw ConfigurationError.invalidDataDirectory }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw ConfigurationError.databaseInUse }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
private struct LeaseKey: StorageKey { typealias Value = DatabaseLease }
struct AccountServiceKey: StorageKey { typealias Value = AccountService }

public func configure(_ app: Application, configuration: ServerConfiguration) async throws {
    guard app.environment == .testing || app.environment == .development else { throw ConfigurationError.localDevelopmentOnly }
    guard configuration.environmentID == "local-development" || app.environment == .testing else { throw ConfigurationError.localDevelopmentOnly }
    let fm = FileManager.default
    try fm.createDirectory(atPath: configuration.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let attrs = try fm.attributesOfItem(atPath: configuration.directory)
    guard (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700,
          attrs[.type] as? FileAttributeType == .typeDirectory else { throw ConfigurationError.invalidDataDirectory }
    app.storage[LeaseKey.self] = try DatabaseLease(path: configuration.directory + "/server.lock")
    let path = configuration.directory + "/server.sqlite"
    let existing = fm.fileExists(atPath: path)
    let crypto = try Cryptography(key: configuration.key, environment: configuration.environmentID)
    app.databases.use(.sqlite(.file(path)), as: .sqlite)
    app.migrations.add(CreateSchema())
    if existing {
        // 在迁移或业务写入前验证原库的环境和密钥，错误时保留原文件。
        guard let marker = try await MetadataRecord.find("key-check-v1", on: app.db),
              try crypto.open(marker.value, context: "metadata") == Data("AzureFishServer".utf8) else {
            throw ConfigurationError.keyMismatch
        }
    }
    try await app.autoMigrate()
    if !existing {
        let marker = MetadataRecord()
        marker.id = "key-check-v1"; marker.value = try crypto.seal(Data("AzureFishServer".utf8), context: "metadata")
        try await marker.create(on: app.db)
    }
    app.passwords.use(.bcrypt(cost: configuration.bcryptCost))
    let dummyHash = try await app.password.async.hash(Cryptography.randomToken())
    let service = AccountService(crypto: crypto, dummyHash: dummyHash, clock: configuration.clock)
    app.storage[AccountServiceKey.self] = service
    app.http.server.configuration.hostname = "127.0.0.1"
    app.http.server.configuration.port = 8080
    app.routes.defaultMaxBodySize = "16kb"
    app.middleware = .init()
    app.middleware.use(APIMiddleware(limiter: service.limiter))
    app.get("health") { _ in
        var result = HealthResponse()
        result.status = "ok"; result.environmentID = configuration.environmentID
        return try protobufResponse(result)
    }
    let v1 = app.grouped("v1")
    v1.post("auth", "register", use: service.register)
    v1.post("auth", "login", use: service.login)
    v1.post("auth", "refresh", use: service.refresh)
    v1.post("auth", "logout", use: service.logout)
    v1.get("me", use: service.me)
    v1.patch("me", use: service.update)
}
