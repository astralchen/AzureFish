# 客户端本地网络包

> 状态：三个本地 SPM 已实现并链接到 AzureFish App target。Swift 6.3，最低 iOS 15。本轮新增包内会话管理器与 IM 提示适配器；现有 App SessionCoordinator 保持原流程，新实时连接未接入 App。

实现与使用入口见 [SharePackage](../../SharePackage/README.md)。本轮借鉴 Nirvana 的模块边界，采用 AzureFish 命名及 HTTP＋Protobuf 服务契约；Nirvana 只作为设计参考，不是构建依赖。

## 模块边界与接口

| 模块 | 公开能力 | 留给后续应用层 |
| --- | --- | --- |
| AzureFishProtocol | 服务端生成消息、optional presence、未知字段兼容 | 不提供 UI／存储领域模型 |
| AzureFishNetwork | HTTPRequest／HTTPResponse、HTTPTransport、HTTPClient、URLSessionHTTPTransport、WebSocketConnection、WebSocketRequestBroker、MessageRouter | 不识别账号与业务 401，不持久化请求 |
| AzureFishAPI | APIEnvironment、AccountAPI、AccountOperation、SessionCredentials、UserProfile、APIClientError、APISessionManager、IMRealtimeClient | 生产安全存储、应用路由、IM 增量落库与 UI |

当前 API 包不实现 Apple、头像、改密、删除账号与 IM 业务消息读写。文本 IM 服务端已于 2026-09-27 提供[本机接口](../../AzureFishServer/Documentation/im-contract.md)，已提供独立 IM 实时提示适配器，客户端 HTTP 同步／聊天接入仍待实施。业务层以后通过依赖注入创建 AccountAPI，不另建全局网络／语言／会话单例。

协议来自服务端 `Protos/azurefish.proto`，客户端保存同步的 `Sources/AzureFishProtocol/azurefish.proto` 副本和 generation.json；消息与字段的中文注释也在 proto 中维护。SwiftProtobufPlugin 在 SwiftPM／Xcode 构建时自动生成公开 Swift 类型，产物仅位于构建目录，不提交客户端 `.pb.swift`。普通构建使用锁定依赖自带的生成工具，不读取服务端目录。SwiftPM 所需的占位 Swift 文件仅含注释，详见[协议包说明](../../SharePackage/AzureFishProtocol/README.md)。

网络使用系统 TLS；URLSession 临时配置禁用缓存、cookie、凭据存储与重定向。Debug 回环 HTTP 仅可在 macOS／模拟器显式启用，Release 与真机必须 HTTPS。未修改 App ATS 或 UI 行为。

## 接入顺序

1. 已完成：将 AzureFishProtocol、AzureFishNetwork、AzureFishAPI 三个本地 products 加入 App target；客户端可按需 import，独立 AzureFishNetworking 工作区继续用于包测试。
2. 后续迁移：为 APISessionManager 提供与现有 Keychain 格式衔接的存储适配；App 本轮继续使用 SessionCoordinator。
3. 实现 UserRepository 的账号加密缓存与版本合并，然后连接认证／个人中心 UI；完整要求沿用[认证接入](../Authentication/client-integration.md)与[安全设计](../Security/README.md)。

各操作先 prepare、再 execute；重试复用原操作和序列化字节。刷新后的受保护重试可换同一 session 的较新 Bearer；如果更换账号／环境／session，创建新的业务流程。离线、业务错误和 HTTP／解码错误分别处理，不能用“所有 401 均刷新”替代业务状态机。

本次证据见[验证记录](validation.md)。

媒体后台契约现已扩展，详见 [服务端媒体接口](../../AzureFishServer/Documentation/media-contract.md)。客户端仅同步权威 proto；上传队列、加密媒体缓存和聊天 UI 接入仍待实施。

WebSocket 与共享会话的详细契约及示例见 [Network](../../SharePackage/AzureFishNetwork/README.md)、[API](../../SharePackage/AzureFishAPI/README.md)；本轮验证见 [WebSocket 验证记录](websocket-validation.md)。
