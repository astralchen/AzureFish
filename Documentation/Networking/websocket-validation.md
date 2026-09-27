# WebSocket 增强验证记录

日期：2026-09-27。环境：Swift 6.3.2、macOS、本机虚构数据。变更在 AzureFish 内独立实现，Nirvana 只作为设计参考，没有新增路径依赖。

## 本轮范围

- AzureFishNetwork：原生传输、actor 连接、独立尝试代次、共享握手、心跳、重连、有界收发、发送收据、请求配对、路由及可控测试工具。
- AzureFishAPI：强制注入安全存储的 APISessionManager、共享刷新与 pending operation 恢复、IMRealtimeClient 提示适配。
- 未改变服务器运行接口、关闭码、Protobuf 或 App SessionCoordinator，没有自动启动 App 实时连接。

## 验证命令与证据

| 检查 | 结果 |
| --- | --- |
| Network 包单元与原生回环测试 | 通过：32 项，包含原生连接空闲 16 秒后的 ping／pong 与收发 |
| API 包及会话／IM Mock 回归 | 通过：21 项执行通过；2 项真实服务用例默认跳过，随机端口用例另行执行 |
| Protocol 包回归 | 通过：4 项，协议插件生成及未知字段／消息信封兼容 |
| 随机回环端口真实 IM 联调 | 通过：客户端真实服务用例 1 项＋服务端隔离夹具 1 项；提示、刷新、退出、1008 和 401 全部通过 |
| iOS Simulator 编译 | 通过：App workspace，x86_64，最低部署 iOS 15，CODE_SIGNING_ALLOWED=NO |
| 文档链接与 git diff --check | 通过 |

```sh
swift test --package-path SharePackage/AzureFishNetwork -j 4
swift test --package-path SharePackage/AzureFishAPI -j 4
swift test --package-path SharePackage/AzureFishProtocol -j 4
AZUREFISH_RUN_CLIENT_REALTIME=1 swift test --package-path AzureFishServer \
  --filter ClientRealtimeHarnessTests -j 4
xcodebuild -workspace AzureFish.xcworkspace -scheme AzureFish \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/AzureFish-WebSocket-DD ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Network Mock 覆盖：共享握手取消、握手／发送／pong 超时、旧传输回调隔离、重连耗尽、停止后重连与终态、有界字节队列／顺序、已提交发送不确定性、慢订阅和订阅前缺口、消息大小、请求快速响应／重复身份／超时／取消／迟到结果、Router 注销期间快照回调、连接释放。原生 URLSession 测试使用 Python 标准库随机回环服务，验证文本、二进制、ping／pong、1008、401、拒绝重定向与大小限制。

API Mock 覆盖：HTTP 与实时确认共享刷新、刷新响应丢失后的相同请求字节恢复、新凭据存储失败、旧 401、显式认证错误分类、清理／切账号时旧刷新隔离、退出期间认证重试、提示解析、凭据旋转、1008 认证和非认证分支、离线确认及畸形提示。存储测试实现只在测试 target 内，未交付生产内存回退。

真实 IM 联调夹具只添加在服务端测试 target，生产服务没有客户端依赖。夹具创建独立临时库／密钥与随机端口，再运行 API 已编译的测试；验证初始提示、凭据旋转后新提示、客户端退出停止连接，以及独立旧 Bearer 连接被服务端 1008 关闭、旧 Bearer 新握手被 401 拒绝。拒绝使用 8080。

## 边界与未执行项

- 原生 URLSession 的 ping／pong 验证维持 receive 循环；WebSocketConnection 自动维持该循环。首次完整回归暴露了测试只调用 ping 而没有活动 receive 的等待，已修正测试契约并复验。
- 独立 AzureFishNetworking 工作区的测试 scheme 无普通 Simulator build 目标，Simulator 编译改由 App workspace 完成。
- App 新管理器迁移、Keychain 格式迁移、前后台恢复、HTTP IM 同步落库、聊天 UI：未实施。
- 模拟器 UI、人工视觉、iPhone／iPad 真机、生产 WSS／真实证书服务、Linux：未执行。本轮不涉及界面变更。
- 存储协议要求原子安全保存，生产 Keychain 适配需后续接入。普通离线保留会话；退出失败保留存储并明确报错，需保留 operationID 重试或显式本机清理。

原生传输 API 的握手回调、重定向和消息大小边界参考 [Apple URLSessionWebSocketTask 文档](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask)。本轮运行结果来自上述测试，不能据此推定未运行的平台已通过。
