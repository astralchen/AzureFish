# 聊天功能迁移记录

最新状态：已于 **2026-09-24** 同步到 `54d74d9`，详见 [增量同步与验证记录](Documentation/ChatMigration/sync-2026-09-24.md)。当前聊天模块为 **121 个 Swift 文件**。以下保留 2026-09-22 首次迁移档案，首次构建与测试结果不代表本轮结果。

日期：2026-09-22。

来源：`QuickLayoutKit/Demo/Demo/Features/Chat`，提交 `84c64cb44be82250df0114f4f28ae50a2fc720c9`。本次按复制方式迁移，源工程未修改。

## 已接入

- 122 个聊天 Swift 文件、共享并发工具、多语言支持及 37 个媒体资源文件。
- 37 个单元/组件测试源文件、10 个原有 UI 测试文件，以及 1 个 AzureFish 正常入口测试文件。
- `AzureFish`、`ChatRegression`、`MediaBenchmark` 共享 scheme 和媒体性能脚本。
- 麦克风、语音识别、相册读取与保存权限声明，以及中/英/阿拉伯语权限文案。
- QuickLayoutKit、ListKit、AppLocalization 远程包引用；当前工程使用 main 分支，实际测试提交由 workspace 的 `Package.resolved` 记录。没有本地框架副本或相邻工程路径依赖。
- iOS 15.0 部署目标：iOS 26+ 使用现有液态玻璃聊天页面，iOS 15～25 使用待适配基础入口。

聊天代码除日志子系统命名外保持来源实现。测试调整了导入模块和限定类型名、语言偏好键、旧系统可用的等待 API，以及照片导入测试的版本保护。
正常启动直接进入聊天页；Debug UI 回归使用单会话入口验证返回与重启恢复。

## 本次验证

| 验证 | 结果 |
| --- | --- |
| 源码复制完整性 | 122 个 Swift 文件逐一比对通过，业务实现无意外差异 |
| 媒体资源完整性 | 37 个文件 SHA-256 与源工程一致 |
| 本地化及工程配置 | 使用到的字面量文案键无缺失；plist、iOS 15 部署目标、远程包引用及 diff 检查通过 |
| App 与测试编译 | Debug `build-for-testing` 通过，App、单元测试和 UI 测试目标均编译成功 |
| 单元/组件测试 | DemoTests、ChatDraftTests、ChatMessageMenuPreviewTests，52 项通过，0 失败 |
| 正常入口 UI | 启动后直接进入聊天、输入与发送通过 |
| 草稿 UI | 页面退出恢复、进程重启恢复、发送后清空通过 |
| 中文菜单 UI | 中文长按消息菜单通过 |
| 正常启动画面 | 已检查默认媒体历史及输入栏截图 |
| iOS 15～25 运行 | 未执行；本机仅安装 iOS 27.0 模拟器，旧系统完整聊天 UI 待后续实现 |
| 真机、真实录音、语音识别与相册写入 | 未执行 |
| 完整回归矩阵、性能 A/B | 未执行；已迁移对应测试和工具 |

环境：Xcode 27.0（27A266a），iPhone 18 Pro 模拟器，iOS 27.0。

构建有 Xcode 自带测试框架最低版本为 iOS 17 的链接警告；这是测试宿主限制，App 部署目标仍为 iOS 15。该构建不能代替旧系统运行验证。

证据文件：

- `/tmp/azurefish-chat-build-final.log`
- `/tmp/azurefish-chat-tests.log`
- `/tmp/AzureFish-Chat-Verification.xcresult`
- `Documentation/ChatMigration/launch-ios27.png`

## 后续开发边界

- iOS 15～25 的聊天 UI 从 `AzureFish/App/LegacyChatViewController.swift` 继续接入；本次只提供基础入口。
- 发送、自动回复、初始历史和历史分页仍为本地模拟流程，真实 App 后端需后续接入。
- App 目前保留原来的联系人、样例消息和媒体资源，便于继续开发及回归。
- `AzureFish/Features/Chat/README.md` 内的旧测试记录来自 QuickLayoutKit，不能作为新工程验证结果。
