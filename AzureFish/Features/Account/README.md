# 账号客户端

Account 参照 [Chat](../Chat/README.md) 按职责组织认证、个人资料、账号安全和安装偏好代码。页面使用 UIKit、QuickLayoutKit 与 ListKit，会话操作继续通过 `SessionCoordinator` 和 `AzureFishAPI` 协调。

## 目录与职责

```text
Account/
├── Controllers/       页面生命周期、导航、表单交互和 Debug 场景页面
├── Models/            账号资料、认证输入、凭据快照、账号提示和校验规则
├── Views/
│   ├── Avatar/        共享头像视图
│   ├── Forms/         标签、输入和密码显示控件
│   ├── Profile/       个人中心菜单和简介文本视图
│   └── Settings/      设置分组说明
└── Support/           会话协调、服务注入、Keychain、加密缓存和头像处理
```

独立类型按主要类型名分文件。欢迎页与认证表单、个人中心与资料编辑、设置与恢复页面分别组织；头像视图、选择器协调器和确认页面各自承担展示、系统选择和提交职责。`AccountScreen` 是共享页面容器，放在 Controllers；`AccountField` 是可复用输入组件，放在 Views。

当前表单状态由对应控制器持有，账号级状态由 `SessionCoordinator` 管理。新增独立页面状态对象或自定义转场时，再按 Chat 的约定增加 `ViewModels` 或 `Animations` 目录。

## 会话与存储边界

- `SessionCoordinator` 统一管理恢复、认证、资料操作、连接状态和退出，并保留代次校验、取消及失败重试语义。页面通过既有接口观察和提交操作。
- `AccountServicing` 与 `LiveAccountService` 提供服务注入；`AuthenticationInput` 只保存当前表单的重试输入。输入校验与本地化错误键分别位于 `AccountValidation`、`AccountFailure`。
- `SecureValueStoring` 定义受保护存储接口，`KeychainValueStore` 执行系统 Keychain 读写，`CredentialStore` 管理会话包、账号提示及撤销队列，`KeychainAPISessionStore` 将同一份凭据适配给网络会话管理器。`StoredSession` 与 `RememberedLoginAccount` 分别描述凭据快照和登录提示。
- `UserRepository`、`AccountAvatarCache` 和 `AccountBusinessStorage` 保留现有账号隔离与资源所有权；头像请求复用和失效由 `AccountAvatarLoader` 管理。
- `AppearancePreference` 管理安装级外观，语言沿用 AppLocalization；页面重绘继续保留已有输入控件、导航和会话状态。

本次整理仅调整代码组织与引用路径，网络契约、存储格式、Keychain 项名称和资源清理顺序沿用现有实现。

## 预览与验证

页面和组件的预览保留在对应源文件末尾的 `#if DEBUG` 中。`AccountDebugScenario` 及其场景控制器整体受 DEBUG 条件保护，Release 不包含这些声明；预览和调试场景不代表真实服务联调结果。

单元与组件测试位于 `AzureFishTests/Account`。构建使用仓库的 `AzureFish.xcworkspace` 与 `AzureFish` scheme，重点回归会话恢复与取消、存储隔离、头像加载、表单布局、设置和安全页面。

包含系统 Keychain 往返用例时，模拟器测试宿主需启用签名。本次在 iPhone 17 Pro／iOS 26.5 上使用 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 本地签名构建，47 项单元与组件测试全部通过；未签名产物在调整前后均于 Keychain 读取时报 `.storage`。这些参数仅用于本地模拟器验证，不修改项目的真机或发布签名配置。

`Scripts/account-client-tests/Sources/AzureFish` 通过符号链接共享部分应用源码。拆分或移动这些类型时同步更新链接，并保持所需声明完整；链接检查不能代替主机编译或模拟器运行验证。
