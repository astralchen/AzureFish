# 客户端本地网络包

> 状态：三个本地网络 SPM 已实现并链接到 AzureFish App target。Swift 6.3，最低 iOS 15。App 的 SessionCoordinator 已注入共享 APISessionManager，聊天业务由 AzureFishChat 连接 HTTP 同步与实时提示；具体功能验收以对应记录为准。

实现与使用入口见 [SharePackage](../../SharePackage/README.md)。本轮借鉴 Nirvana 的模块边界，采用 AzureFish 命名及 HTTP＋Protobuf 服务契约；Nirvana 只作为设计参考，不是构建依赖。

## 模块边界与接口

| 模块 | 公开能力 | 包外职责 |
| --- | --- | --- |
| AzureFishProtocol | 服务端生成消息、optional presence、未知字段兼容 | 不提供 UI／存储领域模型 |
| AzureFishNetwork | HTTPRequest／HTTPResponse、HTTPTransport、HTTPClient、URLSessionHTTPTransport、WebSocketConnection、WebSocketRequestBroker、MessageRouter | 不识别账号与业务 401，不持久化请求 |
| AzureFishAPI | APIEnvironment、AccountAPI、AccountOperation、SessionCredentials、UserProfile、APIClientError、APISessionManager、IMAPI、MediaAPI、IMRealtimeClient | 生产安全存储、应用路由、IM 增量落库与 UI |

当前 API 包提供头像、改密、全部设备退出、删除账号、IM 业务读写和媒体传输，Apple 认证尚未提供。账号及 IM 契约由服务端维护，见[账号契约](../../AzureFishServer/Documentation/protobuf-contract.md)与[IM 接口](../../AzureFishServer/Documentation/im-contract.md)。业务层通过依赖注入创建 AccountAPI，不另建全局网络／语言／会话单例；接口存在和登录成功不代表真实服务及完整 IM 已通过验收。

协议来自服务端 `Protos/azurefish.proto`，客户端保存同步的 `Sources/AzureFishProtocol/azurefish.proto` 副本和 generation.json；消息与字段的中文注释也在 proto 中维护。SwiftProtobufPlugin 在 SwiftPM／Xcode 构建时自动生成公开 Swift 类型，产物仅位于构建目录，不提交客户端 `.pb.swift`。普通构建使用锁定依赖自带的生成工具，不读取服务端目录。SwiftPM 所需的占位 Swift 文件仅含注释，详见[协议包说明](../../SharePackage/AzureFishProtocol/README.md)。

网络使用系统 TLS；URLSession 临时配置禁用缓存、cookie、凭据存储与重定向。Debug 回环 HTTP 仅可在 macOS／模拟器显式启用，Release 与真机必须 HTTPS。未修改 App ATS 或 UI 行为。

## 接入顺序

1. 已完成：将 AzureFishProtocol、AzureFishNetwork、AzureFishAPI 三个本地 products 加入 App target；客户端可按需 import，独立 AzureFishNetworking 工作区继续用于包测试。
2. 已完成：SessionCoordinator 注入 KeychainAPISessionStore，与现有 Keychain 格式衔接；共享 APISessionManager 协调刷新与退出。
3. 已有 UserRepository 的账号缓存与版本合并、认证／个人中心 UI，以及 AzureFishChat 的聊天数据同步与实时提示接入。完整职责和验收边界沿用[认证接入](../Authentication/client-integration.md)与[安全设计](../Security/README.md)。

各操作先 prepare、再 execute；重试复用原操作和序列化字节。刷新后的受保护重试可换同一 session 的较新 Bearer；如果更换账号／环境／session，创建新的业务流程。离线、业务错误和 HTTP／解码错误分别处理，不能用“所有 401 均刷新”替代业务状态机。

AccountAPI 的 prepare 方法默认生成新的 `operationID`，普通新操作可省略该参数；execute 及其重试沿用操作内的原 ID 和字节。需要重新准备恢复操作时显式传入保存的原 ID 和原始输入。IMAPI／MediaAPI 的写方法同样提供默认值，但再次调用直接发送方法代表新操作；手动重试或恢复须显式复用原 ID 和请求内容。联系人保存原始字节，消息、媒体上传、刷新和退出补偿保留已有的身份保存与恢复流程。使用示例见 [API README](../../SharePackage/AzureFishAPI/README.md#使用方式)。

本次证据见[验证记录](validation.md)。

媒体契约见 [服务端媒体接口](../../AzureFishServer/Documentation/media-contract.md)。客户端同步权威 proto；MediaAPI 负责控制及分块传输，AzureFishChat 的上传队列保存创建／完成／取消 ID，恢复时显式传回原身份。加密媒体与聊天 UI 的职责见[数据库文档](../Database/README.md)。

WebSocket 与共享会话的详细契约及示例见 [Network](../../SharePackage/AzureFishNetwork/README.md)、[API](../../SharePackage/AzureFishAPI/README.md)；本轮验证见 [WebSocket 验证记录](websocket-validation.md)。
