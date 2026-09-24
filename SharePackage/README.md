# AzureFish 客户端本地 SPM

本目录为后续客户端认证接入提供可编译的基础包。三个包统一采用 **Swift 6.3**、Swift 6 严格并发，最低 **iOS 15／macOS 12**。仅依赖本仓库内的相邻包和远程 SwiftProtobuf，不依赖 Nirvana 或 AzureFishServer 目录。

| 包／Product | 职责 | 依赖 |
| --- | --- | --- |
| [AzureFishProtocol](AzureFishProtocol/README.md) | 服务端生成的 Protobuf 消息类型与来源清单 | SwiftProtobuf 1.38.1 |
| [AzureFishNetwork](AzureFishNetwork/README.md) | URLSession、请求／响应、取消、传输错误、有界重试 | Foundation |
| AzureFishNetworkTestSupport | 可注入的内存 mock，使用虚构数据断言请求 | AzureFishNetwork |
| [AzureFishAPI](AzureFishAPI/README.md) | 环境、账号 API、错误映射、Sendable 业务值 | AzureFishProtocol、AzureFishNetwork |

分层借鉴 Nirvana 的 WireContracts／NetworkKit／App 适配层；包名、线协议与安全规则采用 AzureFish 自己的约定。本轮实现 HTTP 密码账号闭环，不引入 Nirvana 的业务协议、自定义二进制帧、额外网络加密、全局 AccountManager 或旧 NetworkSession。

应用调用顺序为 `SessionCoordinator／UserRepository → AzureFishAPI → AzureFishNetwork → URLSession`；只有 AzureFishAPI 的网络边界使用 AzureFishProtocol。ViewController 不持有 Protobuf 对象。

## 打开、验证与后续接入

打开 [AzureFishNetworking.xcworkspace](../AzureFishNetworking.xcworkspace)，共享 scheme `AzureFishNetworking` 可测试三个包；选择 My Mac 可执行原生 URLSession fixture 测试。也可单独执行：

```sh
swift test --package-path SharePackage/AzureFishProtocol -j 4
swift test --package-path SharePackage/AzureFishNetwork -j 4
swift test --package-path SharePackage/AzureFishAPI -j 4
```

本轮提供独立工作区，尚未将包链接到 App target，也未修改启动路由。后续在 AzureFish target 添加本地 package `SharePackage/AzureFishAPI` 的 `AzureFishAPI` product，然后 `import AzureFishAPI`；协议包和网络包自动作为依赖构建。测试 target 可额外引入 `AzureFishNetworkTestSupport`。不要以 `AzureFishServer` 或 Nirvana 的本地包作为 App 构建依赖。

实施边界、使用契约和本次验证结果见[网络接入说明](../Documentation/Networking/README.md)。
