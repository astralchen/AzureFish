# 2026-09-28 全 App 功能闭环实施

## 本轮变更

- 隐藏欢迎页 Apple 登录及账号安全 Apple 绑定入口。
- 接入密码再次认证、修改密码、退出全部设备、群主检查和账号删除；输入失败保留，提交中禁止重复操作。
- 头像支持系统选图、正方形预览、独立确认上传、恢复默认；个人资料、通讯录及私聊列表读取同一头像资源。头像按环境／登录账号隔离，AES-GCM 缓存使用独立 Keychain 密钥。
- 个人中心使用 UISplitViewController，按当前 safe area 内容宽度和 size class 切换；编辑完成回到个人中心。原有文字版本冲突流程保留。
- 旧系统聊天补媒体缩略图、系统保存／分享入口、麦克风权限恢复入口；草稿持久化失败显示重试，消息删除、重试及取消失败有反馈。
- 聊天停止等待启动、上传和下载结束，再释放明文租约并关闭数据库。删除申请发送前保存不含密码的独立 Keychain 恢复包；响应丢失时十分钟内原字节重试。确认后使用本机清理标记，启动先恢复清理；文件清理结束后删除对应密钥。退出通知同账号的其他窗口清除会话与明文状态。
- 新文案覆盖简中、繁中、英文、阿拉伯语；保持安装级语言和主题偏好。

## 契约与数据边界

权威接口见[服务端账号安全契约](../../../AzureFishServer/Documentation/account-security.md)。服务端 `.proto` 经同步脚本复制给客户端，客户端 Swift 类型仍由官方插件生成。

删除返回 202 表示已停用并受理清理，保留其他成员已接收历史和媒体引用，不承诺擦除他人副本。普通退出保留加密业务库和密钥。服务仍限隔离虚构账号、回环 HTTP；未加入 Apple 登录、系统推送或生产部署。

## 本次验证

| 项目 | 状态与证据 |
| --- | --- |
| 服务端 Swift Testing | 通过：59 项全量、15 个套件；私有记录清理修正后再通过 6 项账号安全专项复测 |
| iOS 模拟器编译 | 通过：最终签名 build-for-testing，最低部署版本保持 iOS 15 |
| 账号 API 包 | 通过：12 项、2 个套件；包括删除恢复包序列化、原字节重试、过期／跨环境拒绝 |
| 账号单元／组件 | 通过：最终签名复测 19 项、6 个套件全部通过，包含真实 Keychain；未签名首轮失败单独保留记录 |
| iPhone 真实服务 UI | 通过：1 项完整流程，注册、系统选图／正方形预览／上传、取消文字保留头像、恢复默认、改密／重登录、全设备退出／重登录、删除受理／重启 |
| iPad UI | 通过：欢迎页四语言／主题切换、账号安全列表布局与进入实际表单，加上单双列旋转、草稿／焦点及 RTL 连续性，共 3 项 |
| 人工视觉截图检查 | 通过：下列 6 张本轮截图的布局、深浅色和 RTL 展示；范围不等于完整无障碍人工矩阵 |
| 聊天包存储／草稿／搜索回归 | 通过：29 项、8 个套件 |
| 客户端与服务端真实网络联调 | 通过：随机回环端口运行独立客户端测试，覆盖好友、私聊、加密媒体、会话撤销；服务端 harness 与客户端各 1 项 |
| iOS 15～25 实际运行 | 环境阻塞：当前只安装 iOS 26.5 runtime；编译不代替旧系统运行验证 |
| iOS 27.1 专项设备路径 | 环境阻塞：当前无对应 runtime／设备 |
| 真机、真实账号、生产 HTTPS | 未执行，不属于本轮本地联调交付 |
| VoiceOver、降低透明度、增强对比度完整人工矩阵 | 未执行，不以布局测试代替人工验收 |

本记录只认本轮运行证据；设计图、旧截图和历史测试不作为本次通过结果。

模拟器 Keychain 验证需要实际签名的测试宿主。本轮使用 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 的本机模拟器签名；仅 `CODE_SIGNING_ALLOWED=NO` 编译结果不能用于声明 Keychain 运行通过。

## 运行证据

当前模拟器为 iOS／iPadOS 26.5：iPhone 17 Pro、iPad Pro 11 英寸（M5）。以下文件来自本次 XCTest 截图，不是设计稿：

- [iPhone 正方形头像确认](screens/2026-09-28/avatar-square-preview-iphone.png)
- [iPhone 删除申请已受理](screens/2026-09-28/deletion-accepted-iphone.png)
- [iPad 欢迎页深色](screens/2026-09-28/welcome-dark-ipad.png)
- [iPad 欢迎页阿拉伯语](screens/2026-09-28/welcome-arabic-ipad.png)
- [iPad 双列编辑与键盘焦点](screens/2026-09-28/profile-wide-draft-ipad.png)
- [iPad 单列 RTL 与原草稿](screens/2026-09-28/profile-compact-rtl-draft-ipad.png)

头像系统选图已通过真实服务 UI 回归。真实录音及聊天媒体的 Photos 保存尚未执行本轮专项人工验收；接口、缓存与编译结果不替代这些系统交互验证。

## 恢复边界

删除请求的有限期恢复包独立存于 Keychain，只包含原删除请求和旧访问令牌，不保存密码／刷新令牌。恢复窗口为十分钟；窗口外保留加密历史，由用户重新登录确认账号状态，不擅自推断删除成功。修改密码请求及新密码只保留在表单内存中；进程终止后通过重新登录确认账号状态。服务器已确认受理后的本机清理标记可跨重启恢复，不受网络恢复窗口限制。

本次完整结果包（本机临时目录）：`/tmp/AzureFish-Closure-iPad-Final.xcresult` 为 19 项单元／组件与 iPad 自适应 UI；`/tmp/AzureFish-Closure-iPad.xcresult` 为欢迎页四语言／主题和安全列表首轮 UI。服务端日志为 `/tmp/azurefish-server-closure-tests.log`，最终安全专项为 `/tmp/azurefish-security-history-tests.log`，账号 API 为 `/tmp/azurefish-api-closure-tests.log`，聊天包为 `/tmp/azurefish-chat-package-tests.log`，真实网络联调为 `/tmp/azurefish-client-network-tests.log`。

## 回归覆盖对应关系

- `AccountSecurityTests`（服务端）：密码修改撤销所有会话、原字节重放／冲突、proof 用途／会话／过期、群主删除限制、保留对方历史、已退群历史注销身份、头像授权／版本／恢复默认、访问过期后仅允许结果恢复、启动恢复删除标记。
- `AccountAvatarCacheTests`（iOS）：账号与资源隔离、缺失密钥不覆盖、错误密钥及篡改拒绝、删除文件和密钥。
- `AccountAPITests`：删除恢复包不含刷新令牌／密码，序列化后复用原请求字节及原访问凭据，过期或跨环境拒绝。
- `SessionCoordinatorTests`：并发刷新、离线资料恢复、版本冲突保留最新资料、取消登录迟到响应、普通本机退出补偿。
- `ClientChatHarnessTests` 与 `IndependentChatTests`：使用实际客户端、随机回环端口和多个虚构账号，验证好友、私聊、加密媒体和会话撤销。

首轮 UI 脚本曾误选键盘自动填充滚动区、双列中的同名语言菜单及系统 Photos 网格类型，失败结果保留在本机日志；修正依据为实际可访问性层级。仅最终通过项记入上表。

手机完整流程结果包：`/tmp/AzureFish-Closure-Phone-Proof.xcresult`，日志 `/tmp/azurefish-phone-proof-tests.log`。该次功能回归通过后，仅调整删除按钮的语义颜色及头像无障碍标签，再进行最终编译；未将此调整描述为完整 VoiceOver 人工验收。
