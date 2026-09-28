# 登录与个人中心客户端实施记录

> 2026-09-28 更新：头像、账号安全及核心交互已进入代码实施；最新状态与本次验证以[全 App 闭环记录](Implementation/2026-09-28-app-closure.md)为准。下文早期未接入说明属于历史阶段。

更新日期：2026-09-26。范围限定为 Debug 模拟器与本机虚构账号服务；真实账号环境未开放。

## 启动与能力边界

- 正常入口是 `AccountRootViewController`：恢复中性页 → 欢迎页或“聊天／我”；认证成功默认选中“我”。
- 在 Debug 模拟器启动参数中显式添加 `-account-local-development`，才会连接 `local-development` 的 `http://127.0.0.1:8080`。Release、真机和未配置环境显示不可用说明。没有全局 ATS 例外。
- `AzureFishServer/Scripts/run-local.sh` 只供虚构账号联调。客户端工程不依赖服务端目录构建，未修改协议与服务路由。
- 密码注册、登录、刷新、读取／更新资料、当前设备退出使用现有 `AccountAPI`。Apple、头像上传、改密、全部设备退出及删除显示“暂未开放”，不伪造成功。
- 聊天入口明确标记本地演示，保留 `demo.chat` 草稿命名空间；没有把演示草稿迁移到登录账号。
- `-chat-ui-test-root` 保留原回归入口，受 `DEBUG` 编译条件约束。性能脚本原有 `MEDIA_BENCHMARK DEBUG` 条件保持不变。

## 状态与数据职责

| 类型 | 职责 |
| --- | --- |
| AccountServicing／LiveAccountService | 可注入账号 API 与环境，控制器不接触 Protobuf、Bearer 或接口路径 |
| SessionCoordinator | 会话代次、单次刷新合并、pending refresh 恢复、资料版本和撤销补偿 |
| CredentialStore／SecureValueStoring | 原子认证包、独立安装 ID、独立退出队列；Keychain `AfterFirstUnlockThisDeviceOnly` |
| UserRepository | 按环境和账号隔离的 AES-GCM 资料快照，随机 256 位密钥与长度前缀 AAD |
| AccountScreen／AccountField | QuickLayout 页面、原生输入、滚动／键盘安全区域和动态字体 |
| AppearancePreference | 共享安装级外观偏好，在窗口首帧前恢复 |

认证与资料写操作在内存中保留准备完成的操作。同一草稿重试复用 operation ID 和序列化字节，不添加第二套自动传输重试。刷新先原子保存旧凭据与 pending ID，再发送请求；新代凭据安装失败时保留恢复依据。退出废弃当前代次并取消已登记的请求，迟到响应不能重新安装会话。

资料提交只携带发生修改的字段，空简介表示清空。版本冲突读取最新资料，保留草稿并显示最新昵称、简介，由用户确认新版本依据后再次保存。操作结果恢复期限已过时先对账，不盲目重发。服务器接受修改后，本机快照写入失败单独提示，不把已保存修改当作提交失败。

退出先尝试撤销服务端会话。失败后允许明确选择本机退出；独立 Keychain 队列仅保存原退出字节、访问令牌和原到期时间，不保存刷新令牌，不参与登录恢复。普通退出保留加密快照与对应密钥。

## 安全边界

快照信封包含 `format_version`、`key_id`、nonce、ciphertext 和 tag。AAD 由预期环境、账号、资源、用途、版本与 key ID 重建。读取失败、缺失密钥、错误密钥或损坏的原文件不会被新密钥／空快照覆盖。目录排除备份，写入采用受文件保护的原子替换。

当前快照写入只允许 `local-development`。独立 [SQLCipher 验证包](../../Scripts/account-storage-probe/Package.swift) 不链接进应用，也不建设聊天数据库。真实账号上线仍需要完整的设备锁定、系统备份、密钥轮换与旧数据迁移验收；本次虚构账号测试不能代替这些门槛。

## 界面与本地化

使用工程内方案 2 归档。新增页面保持 UIKit、QuickLayoutKit、现有本地化基础控制器和同文件 Debug 预览。原生导航／菜单采用系统当前外观，不把玻璃铺到表单。认证内容最大 440 pt、资料内容最大 600 pt；个人中心在 regular 且可用宽度至少 840 pt 时展开双列。个人中心菜单由 `CollectionListAdapter` 管理稳定 Row 身份，原生 `UICollectionViewListCell` 提供分组、分隔线和 disclosure accessory；列表按实际内容高度参与外层 QuickLayout 页面滚动，避免两层垂直滚动。

`AppLocalization` 增加 `zh-Hant`，现有聊天与系统用途说明补齐独立繁中翻译；新增资源提供简中、繁中、英文和阿拉伯语。语言切换更新现有输入控件，不重新创建表单。账号与密码使用 LTR 语义，品牌和默认图片不镜像。外观沿用 `azurefish.appearance.preference`，语言沿用 `azurefish.locale.identifier`，退出不会重置。

应用设置首页、外观选项页和语言选项页分别由独立的 `UICollectionView` 与 `CollectionListAdapter` 提供页面滚动，不嵌套外层滚动容器。首页分组展示当前偏好及说明，选项页选择立即生效并留在当前页面；原生勾选表示保存的偏好。分组最大宽度 600 pt、水平边距至少 24 pt，窄屏和辅助功能大字体下将摘要放在标题下方。外观选择通过应用内部通知刷新已加载页面，语言继续使用现有场景本地化协调机制；两者都不重建导航栈或业务会话。

账号与安全也使用独立的 ListKit 页面滚动，分为登录方式、安全操作和删除账号三组。当前密码状态只读；Apple 登录、修改密码、退出全部设备及删除账号显示“暂未开放”，点击仅弹出该功能的说明，不发出请求。该页不从资料字段推断尚未实现的登录方式，Debug `security.password` 使用同一列表实现。

VoiceOver 使用可见字段标签、密码显隐标签和错误公告；控件最小触控高度为 44 pt。页面使用 preferred fonts 和多行标签，滚动区域消费键盘安全区域；简介按当前容器宽度测量完整高度，输入时滚动到光标位置，避免重复叠加键盘 inset。运行行为以本次验收记录为准，代码与预览不代表已经通过所有辅助功能场景。

## Debug 状态入口

启动参数 `-account-scenario index` 打开状态目录；`-account-scenario login.error` 等可直接定位设计状态。`AccountDebugScenarios.swift` 包含归档中的 93 个状态 ID。目录在 Release 中不存在，使用无服务的会话实例；系统授权与上传不发出请求。重复状态使用公共表单、反馈与动作视图，演示动作明确标记不提交服务器。

## 可复跑验证

```sh
swift test --package-path SharePackage/AzureFishAPI
AZUREFISH_API_LIVE_TEST=1 swift test --package-path SharePackage/AzureFishAPI --filter LiveAccountAPITests
swift test --package-path Scripts/account-storage-probe
swift test --package-path Scripts/account-client-tests
```

`account-client-tests` 通过符号链接测试同一份应用状态与存储源文件，属于主机单元验证，不替代 iOS UIKit、真实 Keychain 或模拟器测试。

模拟器 Keychain 验收使用 Xcode 临时签名：构建传入 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`；未签名包可编译，但本次无法正常读取系统 Keychain。

模拟器验收复用一台已启动设备，运行 `AccountStorageTests`、`SessionCoordinatorTests`、`AccountLayoutTests` 和 `AccountFlowUITests`；关闭 Xcode 并行测试，避免自动创建多个模拟器。`AccountFlowUITests` 的本机联调用例要求测试进程显式设置 `AZUREFISH_ACCOUNT_UI_LIVE=1`。

注册 UI 测试会关闭模拟器原生强密码建议面板，再输入虚构密码；系统面板语言不受应用内语言控制。应用保留 `.newPassword` 内容类型，真实 Password AutoFill、关联域及真实 Apple 授权未在本轮验证。

本次结果见 [验收记录](Implementation/2026-09-26.md)。个人中心布局后续修正见 [ListKit 专项验收](Implementation/2026-09-27-profile-listkit.md)。

应用设置及独立偏好选项页见 [设置 ListKit 专项验收](Implementation/2026-09-27-settings-listkit.md)。

账号与安全列表见 [安全页 ListKit 专项验收](Implementation/2026-09-27-security-listkit.md)。
