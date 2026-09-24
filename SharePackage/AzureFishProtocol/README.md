# AzureFishProtocol

Swift 6.3 的协议快照 library，最低 iOS 15／macOS 12。`Sources/AzureFishProtocol/Generated/azurefish.pb.swift` 从独立服务端的官方生成器产物原样同步，禁止手改。

- 唯一协议源仍在 AzureFishServer 的 `Protos/azurefish.proto`；客户端不复制或维护另一套 `.proto`。
- 本包没有代码生成插件，普通构建无需 protoc 或服务端目录。SwiftProtobuf 精确锁定 1.38.1，与本次服务端生成版本一致。
- `generation.json` 记录 schema hash、生成 Swift hash、生成器版本／revision；服务端协议来源文件尚未提交或存在未提交修改时 `server_revision` 为 null，以内容 hash 追溯，不伪造 revision。

在 AzureFish 仓库根目录手动同步：

```sh
python3 Scripts/sync-server-protocol.py --server AzureFishServer
python3 Scripts/sync-server-protocol.py --server AzureFishServer --check
```

脚本检查服务端 schema hash、生成标记、依赖锁定及客户端运行库精确版本；`--check` 不写文件，差异以非零退出。生成代码与 `.proto` 的一致性须先通过服务端重新生成验证，客户端同步不替代该验证。正常 App／SPM 构建不调用此脚本。

升级时先修改服务端协议并重新生成，然后审查两个客户端 manifest 中的 SwiftProtobuf 精确版本、同步快照、更新锁文件并运行测试。协议类型留在 API 适配边界，不直接作为页面状态或数据库 schema。
