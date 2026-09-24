# Repository Guidelines

## 项目结构与模块组织

AzureFish 是基于 Swift 6/UIKit 的应用，最低支持 iOS 15。完整聊天功能要求 iOS 26+；旧系统使用 `AzureFish/App/LegacyChatViewController.swift` 兼容入口。消息流程目前采用本地模拟实现。

- `AzureFish/App/`：本地化、系统兼容与 Debug 测试入口。
- `AzureFish/Features/Chat/`：按职责划分为 `Controllers`、`Models`、`ViewModels`、`Views`、`Animations` 和 `Support`。
- `AzureFish/Support/Concurrency/`：共享异步工具。
- `AzureFish/Assets.xcassets`、`AzureFish/Resources/`、`AzureFish/*.xcstrings`：图像资源、媒体测试素材与本地化文案。
- `AzureFishTests/Chat/`、`AzureFishUITests/Chat/`：单元、组件与 UI 测试。
- `Scripts/media-benchmark/`：性能测试工具；`CHAT_MIGRATION.md`：AzureFish 迁移验证记录。聊天模块 README 中的历史结果属于来源工程。

## 构建、测试与开发命令

完整聊天功能开发需要配备 iOS 26+ SDK 和模拟器的 Xcode。在仓库根目录执行：

```sh
open AzureFish.xcworkspace
xcodebuild -workspace AzureFish.xcworkspace -scheme AzureFish \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/AzureFish-DD CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -workspace AzureFish.xcworkspace -scheme AzureFish \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' \
  -derivedDataPath /tmp/AzureFish-DD CODE_SIGNING_ALLOWED=NO \
  -only-testing:AzureFishTests test-without-building
```

以上命令依次打开 Xcode、编译应用及测试、运行单元与组件测试。将 `<SIMULATOR_UUID>` 替换为已安装模拟器的 UUID。本地运行选择 `AzureFish` scheme；专项 UI 回归使用 `ChatRegression`，性能测试使用 `MediaBenchmark`。首次构建需要联网解析并下载 Swift Package 依赖。

## 代码风格与命名约定

使用四空格缩进，类型采用 `UpperCamelCase`，成员采用 `lowerCamelCase`。文件名与主要类型一致；扩展按 `Type+Responsibility.swift` 拆分。沿用中文 `///` 文档注释，说明声明及关键生命周期、并发行为。保留 Actor 隔离和 API 可用性检查。

同步维护中文、英文和阿拉伯语 String Catalog。仓库目前未配置代码格式化或静态风格检查工具。

## UI 布局与预览

新增或调整 UI 时，优先采用 **QuickLayoutKit 布局 + `#Preview` 预览**，参考 `AzureFish/Features/Chat/` 的现有实现。

- 页面与组件优先使用 `QuickLayoutHostingController`、`QuickLayoutView`，通过 `HStack`、`VStack`、`ZStack` 描述层级、尺寸、间距和对齐；集合内容配合 ListKit 的 `CollectionListAdapter` 管理。
- 新增独立 View、Cell 或 ViewController 时，在同一源文件末尾的 `#if DEBUG` 内提供 `#Preview`，按实际 API 标注可用版本。使用确定性样例覆盖关键状态，按需补充长文本、大字体和 RTL 预览；Chat 模块统一复用 `ConversationPreviewData`，不另建 `+Preview.swift` 或 `Previews` 目录。
- 当 QuickLayoutKit 无法满足具体布局、系统集成或性能需求时，再局部采用 Auto Layout、手动 frame 或其他方案，并简要说明原因。图片缩放、`AVPlayerLayer`、遮罩、手势和自定义转场等精确几何场景可使用手动布局。
- `#Preview` 用于快速检查组件效果；自适应 Cell 还需在真实列表中验证尺寸与复用，页面交互需通过模拟器或真机验证。

## 测试规范

单元与组件测试使用 Swift Testing（`@Test`、`#expect`），UI 流程使用 XCTest/XCUIAutomation。测试类型遵循 `Chat<Feature>Tests`、`Chat<Feature>UITests` 命名，XCTest 方法以 `test` 开头。针对行为变更补充回归测试；当前未配置覆盖率数值门槛。分别报告编译、模拟器测试与真机验证结果。真实录音、语音识别和 Photos 写入测试需显式开启对应测试开关。

## Commit 与 Pull Request 规范

Git 提交标题和正文使用中文，专业术语、代码标识符与文件路径保留原文。标题简短明确，以“新增”“修复”“调整”“移除”等动词说明变更，例如 `移除主 storyboard 引用`、`修复聊天草稿恢复异常`。每次提交聚焦单一主题。PR 应说明行为变化、关联相关 Issue、列出验证结果与限制；涉及 UI 的变更应附截图。保留工作区中无关的修改，并审查依赖锁文件的变更。
