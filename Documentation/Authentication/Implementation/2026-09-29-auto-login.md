# 默认自动登录与上次账号入口

日期：2026-09-29。项目尚未发布，本次直接统一客户端与服务端契约，不增加旧版本兼容分支、不执行线上部署。验证仅使用模拟器及隔离的虚构账号。

## 已实施行为

- 默认保留会话，关闭 App 不等于退出；成功刷新续期 30 天，幂等恢复返回原截止。access 为 15 分钟；撤销、删除或过期会话不能续期。旧 refresh 摘要及操作墓碑随会话延长，结果恢复仍为 10 分钟。
- 同环境的所有窗口共用 SessionCoordinator 和 APISessionManager；分离本地身份恢复与网络验证，缓存先展示，验证后原位开放业务网络和传输队列。
- 校验中／离线可查看本账号缓存及编辑本地草稿，不能发送或上传。恢复连接不提交尚未发送的草稿。缺钥、损坏或缺失缓存进入恢复页；即使联网也不在冷启动时创建空库。新库只允许在密码认证成功后首次初始化。
- 上次账号保存在独立 Keychain 项，普通退出保留提示但清除认证包；主动退出不能被后台恢复。账号删除清理提示。账号提示失败不改变认证结果。
- 登录支持换号、注册及明确取消；注册保持单页，顺序为账号、昵称、密码、确认密码。密码只存在短期表单内存，取消和成功后清除引用；迟到结果不能安装被放弃的会话。
- 新文案提供简中、繁中、英文和阿拉伯语，沿用语言／主题管理、QuickLayoutKit 与同文件预览。

## 验证结果

以下为本次运行结果，不引用历史测试作为本次证据。

| 项目 | 本次结果 |
| --- | --- |
| 协议生成与客户端副本一致性 | 通过 |
| 文档与 diff 检查 | 通过：链接、四语言新增资源和 `git diff --check` |
| 服务端单元及隔离 HTTP 联调 | 通过：60 tests／15 suites，含 realSocketSmoke |
| AzureFishAPI 单元测试 | 通过：28 tests／5 suites |
| iOS 编译、单元／组件测试 | 通过：模拟器 ad-hoc 签名编译；25 tests／5 suites，包含真实 Keychain 和无缓存在线／离线两组参数 |
| 模拟器登录 UI 回归与截图 | 通过：上次账号换号／注册返回、密码显示与 RTL→LTR 输入保持，共 2 个 UI 测试；深色截图已人工检查 |
| App 虚构账号 HTTP 联调 | 通过：注册 → 终止进程／重启恢复 → 编辑资料 → 退出 → 再次重启仍登出；改密 → 上次账号重新登录 → 全设备退出 → 重新登录 → 删除 → 重启欢迎页，共 2 个 UI 测试 |
| 国际化、主题与尺寸 UI | 通过：欢迎页四语言／深浅色／跟随系统；横竖屏及 RTL 切换保留输入；设置页布局，共 3 个 UI 测试 |
| 最大无障碍字号 | 通过：显式设置 accessibility-extra-extra-extra-large，重跑上次账号和设置页，检查动作不重叠、说明不覆盖 Cell；截图人工检查通过，结束后恢复原 large 字号 |
| 真机重启、真实账号服务 | 未执行 |
| iOS 15～25、iPad、iOS 27.1 Duo | 未执行 |
| VoiceOver、降低透明度、增强对比度完整矩阵／多窗口人工操作 | 未执行；共享刷新并发使用会话层自动化覆盖，不代替多窗口端到端验收 |

## 执行命令

- 服务端：`AZUREFISH_RUN_HTTP_SMOKE=1 PROTOC=/tmp/AzureFish-Keyboard-DD/Build/Products/Debug/protoc swift test -j 4`。
- 网络包：在 `SharePackage/AzureFishAPI` 执行 `swift test -j 4`。
- iOS：`xcodebuild -workspace AzureFish.xcworkspace -scheme AzureFish -destination 'platform=iOS Simulator,id=505FE0AF-BD0B-4257-A44A-A3BA1364CF5C' -derivedDataPath /tmp/AzureFish-Keyboard-DD CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing`；测试使用同一目录的 `test-without-building`。
- 协议：服务端生成脚本与 `python3 Scripts/sync-server-protocol.py --server AzureFishServer --check`。

App 联调使用独立临时数据目录和随机密钥，服务端仅监听 `127.0.0.1:8080`，联调结束后已停止，设置 `AZUREFISH_ALLOW_LOCAL_TEST_DATA=1`、`AZUREFISH_DATA_DIRECTORY` 和 `AZUREFISH_KEY_FILE`。测试只通过 `-account-local-development` 访问虚构服务；`.xctestrun` 的 UI 测试 EnvironmentVariables 中显式设置 `AZUREFISH_ACCOUNT_UI_LIVE=1`，不修改正式 scheme。

单元／组件选择 `SessionCoordinatorTests`、`AccountStorageTests`、`AccountSecurityTests`、`AccountLayoutTests`、`ChatComposerFocusTests`；UI 选择 `AccountFlowUITests` 中的上次账号、密码显示、注册重启退出、改密退出删除，以及四语言欢迎页、旋转输入保持和大字体设置用例。测试关闭并行以隔离安装偏好及系统键盘状态。

本机日志：`/tmp/azurefish-auth-server-tests.log`、`/tmp/azurefish-auth-api-tests-final.log`、`/tmp/azurefish-auth-acceptance-tests.log`、`/tmp/azurefish-auth-complete-tests.log`、`/tmp/azurefish-auth-accessible-final-tests.log`；模拟器结果包 `/tmp/AzureFish-AutoLogin-Acceptance.xcresult`、`/tmp/AzureFish-AutoLogin-Accessible-Final.xcresult` 和 `/tmp/AzureFish-AutoLogin-Complete.xcresult`。日志及结果包是本次临时证据，不作为构建输入。

首次全新 DerivedData 构建因依赖编译耗时中止，随后复用已有缓存。首次未签名模拟器测试无法访问 Keychain，改用模拟器 ad-hoc 签名后真实 Keychain 用例通过。回归中发现失效清理竞态，已统一等待同一清理任务；HTTP 联调的账号断言已修正为服务端规范化的小写形式。编译与预览不代表运行验证；本次不改变真实账号上线门槛。

## 界面证据

[上次账号登录页（iPhone 17 Pro／iOS 26.5／深色）](Validation/auto-login-2026-09-29/remembered-login.png)。测试账号为固定虚构数据。

[重启后恢复资料页](Validation/auto-login-2026-09-29/restored-profile.png) · [删除账号后欢迎页](Validation/auto-login-2026-09-29/deleted-account-welcome.png)。以上两张来自隔离虚构账号 HTTP 联调，已人工检查。

[浅色欢迎页](Validation/auto-login-2026-09-29/welcome-light.png) · [阿拉伯语欢迎页](Validation/auto-login-2026-09-29/welcome-ar.png) · [繁体欢迎页](Validation/auto-login-2026-09-29/welcome-zh-Hant.png)。四语言用例使用不配置服务的确定性场景，提示文案属于该测试状态。

[最大无障碍字号登录动作](Validation/auto-login-2026-09-29/remembered-login-largest-text.png) · [最大无障碍字号设置说明](Validation/auto-login-2026-09-29/settings-largest-text.png)。首次截图复核发现底部动作重叠及 supplementary 估算高度不足，已改为动作随表单滚动、按完整文本测量说明高度，并增加组件及 UI 几何断言；最终截图确认没有覆盖。
