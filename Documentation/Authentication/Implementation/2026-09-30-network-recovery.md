# 网络门控、短分块下载与退出失败恢复

日期：2026-09-30。仅修复本次确认的客户端网络问题；不修改服务端契约、Protobuf、公开 API、凭据格式、最低系统版本、依赖或语言资源。测试使用虚构凭据、可控传输及隔离回环端口，不代表真实账号或生产 IM 验收。

## 本次行为

- APISessionManager 在首次发送、认证重试及实际传输任务开始时检查会话代次、取消与业务网络权限。等待共享刷新期间关闭权限，刷新成功或网络失败后调用均以 verificationRequired 结束，不继续发送业务请求；共享刷新本身仍可完成。明确认证拒绝仍传播业务错误，以完成会话清理。显式 validateSession 可在业务网络关闭期间执行，恢复业务权限仍由协调器在确认有效后完成。
- 媒体下载接收上限为分块长度与 64 KiB 的较大值，错误正文上限仍为 64 KiB。短尾块的 401 可解析后共享刷新；403／429 保留业务错误分类。成功响应继续严格校验 206、ETag、Content-Range 和实际长度。
- 退出失败保留页面身份、导航、未提交草稿与凭据，转为离线只读并暂停联网任务。恢复入口重新加载本地会话再校验，有效才原位开放联网；已撤销则清除会话并返回登录入口，持续离线保持只读，存储失败使用现有恢复页且保留原记录。
- 退出重试保留原 operationID，由管理器处理退出中的必要刷新；本机退出的补偿材料使用当前凭据构造，避免保留刷新前 Bearer。明确本机退出后不能恢复登录。普通退出继续保留加密业务数据和存储密钥。
- 个人中心重新加载动作在只读状态走会话恢复；编辑页随会话状态更新保存能力，保持当前输入且不自动提交草稿。

## 验证结果

本节仅记录本次执行结果；编译不替代运行验证。

| 项目 | 本次结果 |
| --- | --- |
| AzureFishNetwork | 通过：32 tests／5 suites，含原生 HTTP 和 WebSocket 随机回环端口测试 |
| AzureFishAPI | 通过：35 tests／6 suites；2 个显式真实服务测试未开启，按配置跳过 |
| 网络门控屏障 | 通过：首次发送／认证重试 × 刷新成功／离线失败四种组合均不越过关闭权限；重新开放后新写请求成功；显式校验可执行 |
| 短分块下载 | 通过：1／31 字节尾块 401 刷新成功；403／429、超过 64 KiB 错误正文、错误状态／ETag／范围／长度拒绝 |
| 会话代次 | 通过：旧刷新及迟到退出响应不能覆盖或清除新会话 |
| iOS 编译 | 通过：Xcode 26.5，iPhone 17 Pro／iOS 26.5 模拟器 ad-hoc 签名 build-for-testing |
| 模拟器会话与存储回归 | 通过：23 tests／2 suites；退出失败后会话有效／已撤销／持续离线／存储读取失败，退出清理存储失败，重复退出与刷新后的本机补偿，认证写入期间明确拒绝仍清理会话 |
| 模拟器针对性交互 | 通过：真实 UIWindow 中触发个人中心恢复动作，编辑页保存按钮只读时禁用／恢复后启用，导航控制器及昵称／简介草稿保持；没有自动 PATCH |
| 文档链接与 git diff --check | 通过：本次修改文档的本地链接可解析，diff 无空白错误 |
| 独立 XCTest UI 流程／人工视觉 | 未执行；针对性交互由 UIKit 组件测试覆盖，不代替完整端到端 UI 验收 |
| 真机／真实账号服务／Apple／iOS 15～25／iPad／Duo／完整无障碍矩阵 | 未执行；本次未改变相关验收门槛 |

## 执行与证据

- 网络包：`swift test --disable-sandbox --package-path SharePackage/AzureFishNetwork --disable-automatic-resolution --scratch-path /tmp/AzureFish-network-review-build -j 4`。
- API 包：`swift test --disable-sandbox --package-path SharePackage/AzureFishAPI --disable-automatic-resolution -j 4`。
- 两个包均将 Swift／Clang module cache 和 SwiftPM cache／config／security 路径指向临时目录，沿用本地已解析依赖；网络包原生测试需要允许回环监听。
- iOS：`xcodebuild -workspace AzureFish.xcworkspace -scheme AzureFish -destination 'platform=iOS Simulator,id=505FE0AF-BD0B-4257-A44A-A3BA1364CF5C' -derivedDataPath /tmp/AzureFish-DD -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing`。测试使用同一 DerivedData、`test-without-building`、`-parallel-testing-enabled NO`，选择 SessionCoordinatorTests 和 AccountStorageTests。
- 临时日志：`/tmp/AzureFish-network-fixes-network-tests.log`、`/tmp/AzureFish-network-fixes-api-tests.log`、`/tmp/AzureFish-network-fixes-build.log`、`/tmp/AzureFish-network-fixes-session-tests.log`。最终模拟器结果包：`/tmp/AzureFish-network-fixes-session-final.xcresult`。临时证据不作为构建输入。

交互测试使用模拟器中的真实窗口承载 UIKit 表单并展开布局，通过菜单选择回调执行实际恢复动作；不以静态 Debug 场景代替网络恢复验证。最终测试结果以上表为准。
