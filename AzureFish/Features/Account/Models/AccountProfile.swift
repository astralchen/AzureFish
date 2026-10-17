import Foundation
import AzureFishAPI

/// 界面和加密快照共享的资料，不包含认证凭据。
struct AccountProfile: Codable, Equatable, Sendable {
    let userID: UUID
    let accountName: String
    var nickname: String
    var bio: String
    let version: Int64
    var avatarID: String? = nil
    init(_ profile: UserProfile) {
        userID = profile.userID; accountName = profile.accountName
        nickname = profile.nickname; bio = profile.bio; version = profile.version; avatarID = profile.avatarID
    }
    init(userID: UUID, accountName: String, nickname: String, bio: String, version: Int64) {
        self.userID = userID; self.accountName = accountName; self.nickname = nickname; self.bio = bio; self.version = version
    }
}
