# AzureFish 客户端本地 SPM

本目录包含客户端网络、账号存储和聊天业务包，统一采用 **Swift 6.3**、Swift 6 严格并发，最低 **iOS 15／macOS 12**。仅依赖本仓库内的相邻包、SwiftProtobuf 及固定 SQLCipher GRDB，不依赖 Nirvana 或 AzureFishServer 目录。

| 包／Product | 职责 | 依赖 |
| --- | --- | --- |
| [AzureFishProtocol](AzureFishProtocol/README.md) | 服务端 proto 副本、官方插件生成的消息类型与来源清单 | SwiftProtobuf 1.38.1 |
| [AzureFishNetwork](AzureFishNetwork/README.md) | URLSession、请求／响应、取消、传输错误、有界重试、通用 WebSocket | Foundation |
| AzureFishNetworkTestSupport | 可注入的内存 mock，使用虚构数据断言请求 | AzureFishNetwork |
| [AzureFishAPI](AzureFishAPI/README.md) | 环境、账号 API、共享会话、IM 实时提示、Sendable 业务值 | AzureFishProtocol、AzureFishNetwork |
| [AzureFishStorage](AzureFishStorage/README.md) | 账号数据库、迁移、事务、加密媒体与引用协调 | Foundation、CryptoKit、SQLCipher GRDB |
| [AzureFishChat](AzureFishChat/README.md) | 类型化领域表、聊天事务、同步、发送与搜索 | AzureFishStorage、AzureFishAPI、GRDB |

分层借鉴 Nirvana 的 WireContracts／NetworkKit／App 适配层；包名、线协议与安全规则采用 AzureFish 自己的约定。现已提供 HTTP 密码账号闭环及独立 WebSocket／会话管理组件，不引入 Nirvana 的业务协议、自定义二进制帧、额外网络加密、全局 AccountManager 或旧 NetworkSession。

应用调用顺序为 `SessionCoordinator／UserRepository → AzureFishAPI → AzureFishNetwork → URLSession`；只有 AzureFishAPI 的网络边界使用 AzureFishProtocol。ViewController 不持有 Protobuf 对象。

## 打开、验证与客户端使用

打开 [AzureFishNetworking.xcworkspace](../AzureFishNetworking.xcworkspace)，共享 scheme `AzureFishNetworking` 可测试三个包；选择 My Mac 可执行原生 URLSession fixture 测试。也可单独执行：

```sh
swift test --package-path SharePackage/AzureFishProtocol -j 4
swift test --package-path SharePackage/AzureFishNetwork -j 4
swift test --package-path SharePackage/AzureFishAPI -j 4
```

`AzureFish.xcodeproj` 已通过仓库内相对路径引用五个本地包，将网络、存储和聊天 products 链接到 AzureFish App target。打开根目录 `AzureFish.xcworkspace` 即可在客户端源文件中按需导入：

```swift
import AzureFishAPI
import AzureFishNetwork
import AzureFishProtocol
```

业务调用优先使用 `AzureFishAPI`；传输配置使用 `AzureFishNetwork`，需要原始协议消息的适配代码使用 `AzureFishProtocol`。账号调用示例见 [AzureFishAPI 使用说明](AzureFishAPI/README.md)。App 继续使用现有 SessionCoordinator；ChatRuntime 接入共享会话和 ChatEngine；AccountBusinessStorage 管理账号资源，保留既有 Keychain 格式。测试 target 可按需额外引入 `AzureFishNetworkTestSupport`，App 不链接该测试 product。服务端与 Nirvana 均不作为 App 构建依赖。

实施边界、使用契约和本次验证结果见[网络接入说明](../Documentation/Networking/README.md)。
