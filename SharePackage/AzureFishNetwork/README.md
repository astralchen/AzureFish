# AzureFishNetwork

Swift 6.3、iOS 15／macOS 12 的 Foundation HTTP 基础包，无 UIKit、SwiftProtobuf、业务错误码、凭据存储或全局会话依赖。

- `HTTPRequest` 为不可变请求，`HTTPTransport` 可替换，`HTTPClient` 统一发送、取消与有限重试。
- 默认 HTTPS。只有 Debug macOS／iOS 模拟器可显式选择 `debugLoopbackForFictionalData`，允许字面地址 127.0.0.1／::1；Release 与真机不开放 HTTP。始终使用系统 TLS 校验。
- URLSession 为 ephemeral，禁用 URLCache、cookie 和凭据存储。拒绝所有重定向，包括同域 307／308，防止 Bearer 和请求正文转发。
- 使用 `URLSession.bytes(for:delegate:)` 按需接收，先检查已知长度，再限制实际解压后数据。默认上限 64 KiB；超限、取消及读取失败结束底层 task。请求默认不活动超时 15 秒，session 总资源上限 60 秒；HTTP 重试按独立 attempt 计算。
- 默认不重试。`readOnce` 对临时连接失败最多重试一次；`idempotentWriteOnce` 仅对超时／连接中断最多重试一次，调用方必须保证服务端幂等。每次发送换 X-Request-ID，正文和业务操作 ID 不变。HTTP 状态码、证书失败、取消、解码错误均不触发传输重试。
- 网络日志默认关闭，仅 Debug 可通过启动参数开启；错误不持有原始正文、完整 URL 或底层 userInfo。请求／响应的 description 与 debugDescription 脱敏，body 仍是供编码／断言使用的内存数据，不承诺反射或内存检查无法访问它。

```swift
import AzureFishNetwork
import Foundation

let client = HTTPClient()
let request = HTTPRequest(
    url: URL(string: "https://your-server.example/health")!,
    headers: ["Accept": "application/protobuf"],
    replayPolicy: .readOnce
)
let response = try await client.send(request)
```

## 调试日志

在 Xcode 的 **Edit Scheme → Run → Arguments → Arguments Passed On Launch** 中添加并勾选 `-AzureFishNetworkLogging true`。这是启动参数，不是环境变量；修改后重新启动进程生效。工程不默认开启此参数。

只接受唯一的 `-AzureFishNetworkLogging` 参数及紧随其后的小写 `true`；缺失、缺值、`false`、其他大小写或重复参数均关闭。Release 始终关闭，不读取 UserDefaults，也不将选择保存到下次启动。

日志使用系统 `OSLog.Logger` 的 debug 级别，subsystem 为 `AzureFish.Network`，category 为 `HTTPClient`。可在 Xcode 调试控制台筛选 `event=`；macOS Console 中启用 Debug 消息并按 subsystem／category 筛选，或执行：

```sh
log stream --level debug --predicate 'subsystem == "AzureFish.Network" AND category == "HTTPClient"'
```

`HTTPClient` 记录 `send`、`response`、`retry`、`failure` 和 `cancelled` 事件。字段包含方法、每次实际发送生成的 request ID、尝试次数、状态码、字节数和错误分类；响应／重试耗时对应本次尝试，最终失败／取消耗时包含整个调用及重试等待，单位均为单调时钟计算的毫秒。发送前失败使用 `requestID=none`、`attempt=0`。HTTP 错误状态仍记录为收到响应，由业务层判断成功与否。

日志不包含 URL、请求／响应头原值、正文、业务操作 ID 或底层错误描述。关闭时不构造日志消息或采集耗时。`AzureFishAPI` 经由 `HTTPClient` 自动获得日志，直接调用底层 transport 不记录这些事件。

`AzureFishNetworkTestSupport` 是单独 product；MockHTTPTransport 保存含原始请求的内存历史，**只应用于虚构测试数据**，不用于生产记录或诊断。

当前未实现头像、文件上传下载、后台传输、SSE、WebSocket、证书固定或自动刷新。这些能力按后续业务单独加入，不以无效果的接口占位。
