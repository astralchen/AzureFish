# AzureFishAPI

Swift 6.3 的账号 API、会话与 IM 提示适配包，最低 iOS 15／macOS 12。覆盖健康检查、注册、密码登录、刷新、当前会话退出及个人资料读写；输出普通 Sendable 值类型，不向页面暴露 Protobuf。

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

## App 集成边界

- CredentialStore 将完整凭据和 pending refresh operation ID 原子保存到 `AfterFirstUnlockThisDeviceOnly` Keychain；APISessionManager 通过注入的存储协议保存完整记录，不提供生产内存回退。
- App 的 SessionCoordinator 通过 KeychainAPISessionStore 注入共享 APISessionManager，复用现有 Keychain 格式；管理器负责共享刷新、pending ID 恢复、账号代次隔离与迟到结果拒绝，页面及联网任务的恢复由协调器编排。
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

## APISessionManager 与 IMRealtimeClient

```swift
func makeRealtime(api: AccountAPI, secureStore: any APISessionStore) async throws -> IMRealtimeClient {
    let session = APISessionManager(api: api, store: secureStore)
    try await session.restore()
    let realtime = IMRealtimeClient(sessionManager: session)
    await realtime.start()
    return realtime
}
```

`APISessionStore` 必须按 environmentID 隔离，原子保存 `APISessionRecord` 的完整凭据和 pending refresh operation ID；保存失败必须保留旧值。一个环境由一个管理器拥有，跨进程互斥由存储实现负责。包内仅测试提供 MemorySessionStore，生产构造没有默认存储。

`install` 先停止旧代次请求，再保存并发布新凭据；`restore` 恢复未完成刷新时复用操作 ID 和确定性请求字节。`execute(AccountOperation)` 与 `profile()` 只在 HTTP 401＋UNAUTHENTICATED 时认证重试一次。HTTP 和实时连接共用刷新；旧 Bearer 的迟到 401 使用已经更新的凭据，不重复刷新。刷新前先持久化旧凭据＋pending ID，成功后先保存新凭据再发布。存储失败不发布未保存的新代次；离线不清除有效会话。

`setNetworkAccessAllowed(false)` 关闭业务网络并取消已登记的传输，等待共享刷新的调用在首次发送或认证重试前重新检查权限，以 `verificationRequired` 结束。共享刷新可完成持久化，不能因此恢复业务权限。首次发送、重试和传输任务开始时同时检查会话代次与取消状态；`validateSession()` 可在业务网络关闭期间显式确认身份，确认成功后由调用方开放业务权限。

`logout(operationID:)` 先停止旧代次，再提交服务端退出和清理存储。失败保留存储和退出中的管理器状态，调用方应保留 operationID 重试，由该方法协调必要刷新；退出期间不向实时订阅发布临时刷新的凭据。App 保留页面、导航及草稿，暂停联网任务并进入离线只读，重新连接时先 `restoreLocal()` 再 `validateSession()`，有效才原位解锁，已撤销则清除凭据并返回登录入口。重试或明确本机退出时，补偿材料使用当前凭据重建并保留原 operationID。`clearLocalSession()` 明确清除本机凭据，不替代服务端撤销，也不处理业务数据库。旧存储写入与新会话安装／清理顺序串行，旧请求结果不能复活已清理会话。

`MediaAPI.download` 的接收容量为请求分块长度与 64 KiB 的较大值；错误正文仍最多 64 KiB，然后解析业务错误。1 字节及短尾块的 401 可触发共享刷新，403／429 保留业务分类。成功下载仍严格要求 206、匹配 ETag、完整 Content-Range 和精确实际长度。验证范围见[网络恢复修复记录](../../Documentation/Authentication/Implementation/2026-09-30-network-recovery.md)。

`IMRealtimeClient` 从环境派生 `/v1/im/live`，每次握手取得最新 Bearer，25 秒 ping、10 秒 pong 超时，仅接受不超过 4 KiB 的二进制 IMSyncHint。页面取得 `IMRealtimeHint`、`IMRealtimeState` 与 `IMRealtimeSignal`，无需 import Protobuf。连接建立／恢复、提示变化和接收缺口触发 HTTP 补拉信号；每订阅只保留最新信号，携带会话作用域。提示 cursor **不是已提交 checkpoint**。

凭据刷新重建连接；退出、账号或 session 替换销毁旧连接与内部订阅。握手 401 或 1008 关闭先调用现有 HTTP 资料接口确认：只有明确认证失败才共享刷新；资料有效则报告 policyClosed，避免把连接限额误判为过期。HTTP 确认离线时停止并报告 confirmation failure，保留会话，由上层在网络恢复后显式 stop/start。

适配器不发送 IM 消息，不维护持久 outbox、HTTP 增量落库、checkpoint 或聊天 UI。服务端关闭码及协议均未修改。

独立真实 IM 联调先编译 API 测试，再运行隔离服务测试：

```sh
swift test --package-path SharePackage/AzureFishAPI -j 4
AZUREFISH_RUN_CLIENT_REALTIME=1 swift test --package-path AzureFishServer \
  --filter ClientRealtimeHarnessTests -j 4
```

该测试创建临时库／随机密钥，监听随机回环端口，通过已编译 API 测试验证提示、刷新和退出，结束后删除临时数据，不使用已有 8080 服务。
