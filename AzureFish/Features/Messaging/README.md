# 消息与通讯录客户端

Messaging 参照 [Chat](../Chat/README.md) 按职责组织客户端代码，负责账号会话接入、会话列表、通讯录、聊天详情和旧系统聊天页面。聊天业务存储、同步与发送队列继续由 `SharePackage/AzureFishChat` 提供。

## 目录与职责

```text
Messaging/
├── Controllers/       页面生命周期、列表绑定、导航与用户交互
├── Models/            列表行、分组、空状态、时间展示和操作错误
├── ViewModels/        LiveChatSession 的时间线状态、发送和媒体适配
├── Views/
│   ├── Chat/          旧系统消息气泡和撤回 Cell
│   ├── Contacts/      联系人及好友申请 Cell
│   ├── Details/       群成员网格 Cell 和分组背景
│   ├── List/          会话行、未读标记和列表状态提示
│   └── Notifications/ 应用内提醒和触摸事件窗口
└── Support/           账号运行环境、存储桥接、媒体、导航工厂和协调器
```

文件名与主要类型一致，独立控制器、模型和视图分别放在自己的文件中。紧密配套的 `UIContentConfiguration` 与内容视图保留在一起。职责扩展使用 `Type+Responsibility.swift` 命名，例如 `LiveChatSession+Sending`、`LiveChatSession+Media` 和 `ChatRuntime+DirectConversation`。当前没有独立转场实现，因此不建立空的 `Animations` 目录。

## 页面和业务边界

- `ConversationPageFactory` 统一选择聊天入口。iOS 26+ 且账号草稿存储与页面租约目录就绪时，创建 Chat 的 `ChatViewController` 并注入 `LiveChatSession`；其他情况使用 `LiveConversationViewController`，包括 iOS 15～25。
- `LiveChatSession` 观察账号时间线，将业务消息适配为 Chat 的展示模型，并协调历史、发送、媒体和阅读状态。它沿用 `ChatSessionProviding` 和对聊天控制器的弱引用，配合 Chat 的 `ChatViewModel` 工作。
- `ChatRuntime` 管理当前账号的聊天资源、列表快照和观察者。账号切换与停止、加密存储及资源租约继续走既有流程；页面和组件不另建账号状态。
- 控制器负责 UIKit 生命周期、列表绑定、导航和操作入口。`LiveChatListController`、`ContactDirectoryController`、`ContactFormController` 分别提供通用列表、通讯录列表和联系人表单基础能力；各具体页面单独成文件。
- `Models` 保存展示数据和展示规则，业务实体继续复用 `AzureFishAPI`、`AzureFishChat`。`Views` 管理布局、复用和可访问性；提醒调度、详情导航、联系人错误提示分别放在 Support 的协调器或扩展中。

本次整理保留现有页面绑定方式和业务调用，不改变网络契约、数据库结构或系统版本入口。

## 布局与预览

沿用 UIKit、QuickLayoutKit 和 ListKit；系统容器与精确几何布局保留既有实现。现有 `#Preview` 随对应页面或组件放在同一源文件末尾的 `#if DEBUG` 中，样例继续复用 `ConversationPreviewData`。预览不替代真实列表中的尺寸、复用和交互验证。

## 验证入口

现有单元与组件测试位于 `AzureFishTests/Chat`，UI 测试位于 `AzureFishUITests/Chat`。结构调整重点验证会话列表展示与空状态、联系人分组、未读标记、详情导航，以及 `LiveChatSession` 与原聊天页面的接入。构建和测试使用仓库根目录的 `AzureFish.xcworkspace` 与 `AzureFish` scheme。
