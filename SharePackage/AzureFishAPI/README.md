# AzureFishAPI

Swift 6.3 的账号 API 适配包，最低 iOS 15／macOS 12。覆盖健康检查、注册、密码登录、刷新、当前会话退出及个人资料读写；输出普通 Sendable 值类型，不向页面暴露 Protobuf。

## 使用方式

```swift
import AzureFishAPI
import Foundation

func registerForTesting(deviceID: UUID) async throws -> AuthenticatedSession {
    // 仅 Debug 的 macOS／模拟器；真实服务使用 HTTPS 的 APIEnvironment。
    let api = AccountAPI(environment: try .localTesting())
    let operation = try api.prepareRegistration(
        operationID: UUID(),
        deviceID: deviceID,
        accountName: "fictional_account",
        password: "Fictional-Password-123",
        nickname: "虚构测试"
    )
    return try await api.execute(operation)
}
```

`prepare…` 是同步序列化，不发送请求。一个用户动作创建一个 UUID 和 AccountOperation，自动／显式重试都保留同一操作。用户修改内容再提交时创建新操作。注册／登录操作包含密码字节，只在短期流程内存持有；结束时释放，不放 UserDefaults、磁盘重试队列或日志。刷新操作不注入 Bearer，避免通用 401 逻辑递归刷新。

受保护操作在执行时显式提供当前凭据：

```swift
func saveBio(api: AccountAPI, session: SessionCredentials, version: Int64) async throws -> UserProfile {
    let operation = try api.prepareProfileUpdate(
        operationID: UUID(),
        changes: ProfileChanges(expectedVersion: version, bio: ""),
        using: session
    )
    return try await api.execute(operation, using: session)
}
```

nil 字段表示不修改，空 bio 表示清空。操作绑定环境、账号、设备和 session，可在同一 session 刷新后传入更高代次的凭据重试；不允许换账号、换 session、换环境或使用低于准备时的代次。APIEnvironment 不提供隐式切换共享单例。

## App 必须补齐的协调层

- CredentialStore 将完整凭据和 pending refresh operation ID 原子保存到 `AfterFirstUnlockThisDeviceOnly` Keychain；本包不保存凭据。
- SessionCoordinator 合并并发刷新，刷新前保存旧凭据＋pending ID，重启后用同一 ID 重建确定性的 RefreshRequest；每次登录／退出／切环境分配 App 账号 generation，安装响应前再次核对，拒绝旧操作覆盖当前账号。
- 普通受保护请求仅在 401＋`UNAUTHENTICATED` 时考虑刷新；刷新请求自身失败不递归。`INVALID_CREDENTIALS`、`REFRESH_REPLAY`、`AUTH_ATTEMPT_EXPIRED`、`REFRESH_SUPERSEDED` 按各自流程处理。离线不清空有效账号数据。
- UserRepository 按 environment＋user_id 与单调 profile version 合并资料，并负责账号范围加密缓存；本包无 URLCache 或资料持久化。
- 退出补偿队列、主题／语言、界面路由、Apple 和本地数据库不在本包中。

`APIClientError.service` 提供稳定 code、白名单 field、HTTP 状态、UUID requestID 和 Retry-After。未知业务码映射 `.unknown`；HTML 代理错误、错误 MIME、截断 Protobuf 分开分类，不作为密码失败或刷新信号。UI 使用现有 AppLocalization 翻译，不直接展示内部枚举或原始响应。

## 显式本机联调

先启动独立 AzureFishServer 的虚构数据服务，再在 AzureFish 仓库根执行：

```sh
AZUREFISH_API_LIVE_TEST=1 swift test --package-path SharePackage/AzureFishAPI \
  --filter LiveAccountAPITests -j 4
```

此测试仅编译进 Debug macOS，固定回环 8080，每次生成独立虚构账号。普通测试默认跳过真实服务调用；测试不会写 Keychain 或改变 App 启动状态。
