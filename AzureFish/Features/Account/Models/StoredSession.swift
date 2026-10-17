import Foundation
import AzureFishAPI

/// 一个原子 Keychain 认证包；pending ID 与旧代凭据共同提交。
struct StoredSession: Codable, Sendable, CustomStringConvertible {
    var environmentID: String
    var userID: UUID
    var deviceID: UUID
    var sessionID: UUID
    private var accessToken: String
    private var accessExpiresAt: Date
    private var refreshToken: String
    private var refreshExpiresAt: Date
    private var refreshGeneration: Int64
    var pendingRefreshID: UUID?
    var description: String { "StoredSession(<redacted>)" }
    init(_ credentials: SessionCredentials, pendingRefreshID: UUID? = nil) {
        environmentID = credentials.environmentID; userID = credentials.userID
        deviceID = credentials.deviceID; sessionID = credentials.sessionID
        accessToken = credentials.accessToken.rawValue; accessExpiresAt = credentials.accessExpiresAt
        refreshToken = credentials.refreshToken.rawValue; refreshExpiresAt = credentials.refreshExpiresAt
        refreshGeneration = credentials.refreshGeneration; self.pendingRefreshID = pendingRefreshID
    }
    func credentials() throws -> SessionCredentials {
        try SessionCredentials(environmentID: environmentID, userID: userID, deviceID: deviceID,
            sessionID: sessionID, accessToken: SessionToken(rawValue: accessToken), accessExpiresAt: accessExpiresAt,
            refreshToken: SessionToken(rawValue: refreshToken), refreshExpiresAt: refreshExpiresAt,
            refreshGeneration: refreshGeneration)
    }
}
