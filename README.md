# AzureFish

基于 UIKit 的新 App，聊天代码迁移自 QuickLayoutKit Demo，最新同步提交为 `54d74d9032e85f310f122493256f41bc04790a41`（2026-09-24）。

## 打开与运行

打开 `AzureFish.xcworkspace`，选择共享 scheme `AzureFish`。首次构建需要下载远程 Swift Package 依赖。

- 最低部署版本保持 **iOS 15.0**，支持 iPhone 和 iPad。
- **iOS 26+**：正常启动直接进入现有液态玻璃聊天页。
- **iOS 15～25**：显示基础适配入口；完整聊天 UI 后续在 `AzureFish/App/LegacyChatViewController.swift` 接入。此迁移尚未实现旧系统聊天界面。
- 消息发送、自动回复、初始历史及历史分页使用原有本地样例和模拟实现，尚未连接真实账号、会话服务或后端。

## 代码与资源

- `AzureFish/Features/Chat/`：完整聊天业务模块，共 122 个 Swift 文件。包括富文本、语音录制与识别、照片/视频/GIF/Live Photo、文件/链接、附件浏览、菜单操作、历史分页、草稿存储及媒体调度。
- `AzureFish/Support/Concurrency/`：聊天使用的异步任务工具。
- `AzureFish/App/`：本地化支持、旧系统适配入口和 Debug UI 测试导航入口。
- `AzureFish/Resources/AttachmentPreviewResources.bundle`：完整样例及测试媒体资源，约 108 MB。
- `AzureFish/Localizable.xcstrings`：聊天、通用操作和语言菜单所需的中/英/阿拉伯语文案。
- `AzureFish/InfoPlist.xcstrings`：应用名称及麦克风、相册、语音识别权限文案。
- `Scripts/media-benchmark/`：媒体性能测试工具；`ChatRegression` 和 `MediaBenchmark` 共享 scheme 已同步迁移。
- `AzureFishTests/Chat/`、`AzureFishUITests/Chat/`：迁移的单元、组件和 UI 测试；测试模块已改为 `AzureFish`。

`Features/Chat/README.md` 随原模块完整保留，其中历史验证记录描述的是来源工程，不能作为 AzureFish 的测试结论。新工程验证记录见 `CHAT_MIGRATION.md`。

## 数据库开发设计

[聊天数据库设计文档](Documentation/Database/README.md) 包含整体架构、完整字段字典、客户端与服务端同步契约、数据生命周期、迁移及验收计划。方案采用 GRDB／SQLCipher 加密 SQLite，覆盖私聊、群聊、历史漫游和后续社交扩展。

**当前为设计阶段，尚未接入应用。** 本次仅提供 Markdown 文档，不包含数据库实现或迁移脚本，现有聊天仍使用本地模拟数据流程。

## 登录与服务端开发设计

[客户端登录与个人中心设计](Documentation/Authentication/README.md) 说明 URLSession／SwiftProtobuf 接入、Keychain 会话管理、苹果风格页面及验收要求；[独立 AzureFishServer 文档](../AzureFishServer/README.md) 定义 Swift＋Vapor 服务端、账号密码与 Apple 登录、用户资料、头像和协议字段。

**状态：设计阶段，尚未接入应用。** 两个工程分别管理客户端和服务端数据，网络采用 HTTPS＋Protobuf；后续 IM 复用用户与登录会话。本轮只建立文档，服务端尚不能启动，客户端启动路径与现有聊天演示保持当前实现。

## 安全、设备适配与国际化设计

[数据安全与加密](Documentation/Security/README.md) 规定客户端加密库／媒体、Keychain、TLS 和恢复；[多设备 UI／UX](Documentation/Design/README.md) 规定 iPhone、iPad、iOS 27.1 iPhone Duo 的尺寸与状态适配；[四语言国际化](Documentation/Internationalization/README.md) 规划简中、繁中、英文和阿拉伯语。

**状态：设计阶段，尚未接入应用。** 本轮没有改动页面、语言资源、密钥或依赖；现有资源仍为三语言。跨主题实施验收见 [安全／适配／国际化矩阵](Documentation/Security/validation.md)。

## 远程框架依赖

所有框架通过远程 Swift Package 引用，工程中不复制框架源码，也不依赖相邻工程目录。当前三个直接依赖使用 `main` 分支，以下是本次验证时锁文件记录的具体提交。

| 框架 | 本次解析 revision |
| --- | --- |
| QuickLayoutKit | `54d74d9032e85f310f122493256f41bc04790a41` |
| ListKit | `005aaa36780a1db0850cee7dbccc826886935905` |
| AppLocalization | `a15471628569cb10404f599466b11f1036f9c86b` |

QuickLayout 和 swift-syntax 由依赖图间接引入。`AzureFish.xcworkspace/xcshareddata/swiftpm/Package.resolved` 保存解析结果。

## 测试

Xcode 的 Test 导航器可运行迁移测试。示例命令：

```sh
xcodebuild -workspace AzureFish.xcworkspace -scheme AzureFish \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/AzureFish-Chat-DD CODE_SIGNING_ALLOWED=NO build-for-testing

xcodebuild -workspace AzureFish.xcworkspace -scheme AzureFish \
  -destination 'platform=iOS Simulator,id=<模拟器 UUID>' \
  -derivedDataPath /tmp/AzureFish-Chat-DD CODE_SIGNING_ALLOWED=NO \
  -only-testing:AzureFishTests test-without-building
```

现有聊天 UI 回归通过 Debug 参数 `-chat-ui-test-root` 进入一个单会话测试列表，以保留返回、再次进入及草稿恢复的测试场景；正常启动直接进入聊天页。语言偏好键已改为 `azurefish.locale.identifier`。`AzureFishLaunchTests` 验证正常启动路径。

真实录音、语音识别及相册写入测试沿用原有显式开关；默认运行不代表这些权限和真机媒体流程已验收。

本轮动画测试与日志参数修复详见 [2026-09-24 验证记录](Documentation/ChatMigration/animation-diagnostics-2026-09-24.md)。
