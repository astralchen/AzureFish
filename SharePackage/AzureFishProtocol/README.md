# AzureFishProtocol

Swift 6.3 的协议 library，最低 iOS 15／macOS 12。协议类型由官方 `SwiftProtobufPlugin` 在构建时生成，客户端不提交或手改 `.pb.swift`。proto 通过 `option swift_prefix = "";` 生成 `RegisterRequest`、`AuthResponse` 等简短名称，网络包名仍为 `azurefish.v1`。

## 文件与构建

- `Sources/AzureFishProtocol/azurefish.proto`：从 `AzureFishServer/Protos/azurefish.proto` 同步的契约副本，包含中文消息和字段注释。修改权威服务端协议后再同步，不在客户端独立修改。
- `Sources/AzureFishProtocol/swift-protobuf-config.json`：生成输入和 `Public` 可见性配置。
- `Sources/AzureFishProtocol/AzureFishProtocol.swift`：仅含注释的 SwiftPM target 识别占位文件，没有协议或业务实现；删除会导致 target 被识别为空。
- `generation.json`：协议内容 hash、SwiftProtobuf 版本／revision 和来源提交记录；来源尚未提交或有修改时 revision 为 null。

SwiftProtobuf 精确锁定 1.38.1。该版本的插件依赖自带的 `protoc` 和 `protoc-gen-swift` 工具，由 SwiftPM／Xcode 构建，不要求手工安装系统 protoc；首次构建需要下载依赖并编译工具。请勿配置机器专用的 `protocPath` 或 `PROTOC_PATH` 覆盖默认工具。

生成的 Swift 位于 SwiftPM `.build` 或 Xcode DerivedData 的插件输出目录，不写回 Sources，也不复制 proto 到 App 资源。源码注释会随生成器转换为 Swift 文档注释。

## 同步与验证

在 AzureFish 仓库根目录执行：

```sh
# 修改服务端协议后先按服务端说明重新生成其产物与清单。
python3 Scripts/sync-server-protocol.py --server AzureFishServer
python3 Scripts/sync-server-protocol.py --server AzureFishServer --check
swift test --package-path SharePackage/AzureFishProtocol -j 4
```

同步脚本检查服务端 schema hash、版本锁定、客户端插件配置及运行库精确版本，然后复制 proto 和来源清单；`--check` 仅比较，差异以非零退出。普通客户端构建只读取包内副本，不调用同步脚本，也不依赖服务端目录。

增添新 proto 时同步扩展同步脚本和插件配置的 `protoFiles`。协议类型留在 API 适配边界，不直接作为页面状态或数据库 schema。字段编号、类型和 optional presence 的变更须经过契约审查；本次仅添加注释和 Swift 命名选项，未改变线协议。

同时导入 AzureFishAPI 时，原始协议资料用 `AzureFishProtocol.UserProfile`，业务资料用 `AzureFishAPI.UserProfile` 消除同名歧义；一般业务调用仍优先使用 AzureFishAPI 的领域类型。
