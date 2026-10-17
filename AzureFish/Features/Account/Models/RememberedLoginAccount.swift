import Foundation

/// 登录页使用的账号提示，不是认证凭据，也不能授权打开账号存储。
struct RememberedLoginAccount: Codable, Equatable {
    let environmentID: String
    let userID: UUID
    let accountName: String
}
