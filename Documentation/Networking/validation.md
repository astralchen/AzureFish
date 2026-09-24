# 本地 SPM 验证记录

日期：2026-09-24。工具链：Apple Swift 6.3.2；三个包均声明 `swift-tools-version: 6.3`、Swift 6 语言模式，最低 iOS 15／macOS 12。测试运行平台为 Intel macOS。

## 结果

| 验证 | 状态 | 本次证据与边界 |
| --- | --- | --- |
| AzureFishProtocol Swift Testing | 通过 | 2 项：optional presence、Int64 极值、未知字段往返 |
| AzureFishNetwork Swift Testing | 通过 | 8 项：精确字节重试、不同 request ID、重试上限、安全地址／请求头、错误／取消不重试、描述脱敏，以及原生 URLSession fixture |
| AzureFishAPI 模拟测试 | 通过 | 9 项，其中业务 401 用例有 4 组参数；真实服务用例默认跳过，不计入这 9 项 |
| 原生 URLSession fixture | 通过 | 临时回环 Python HTTP 服务验证禁止重定向、无缓存／cookie、已知与未知长度超限中止、取消实际任务 |
| AzureFishAPI 真实 HTTP 联调 | 通过 | 显式 `AZUREFISH_API_LIVE_TEST=1` 单独运行 1 项，使用虚构数据后端和真正 URLSession |
| iOS 15 模拟器目标编译 | 通过 | `AzureFishAPI` scheme，显式 `IPHONEOS_DEPLOYMENT_TARGET=15.0`；包含三个包及 SwiftProtobuf；不是 iOS 15 运行测试 |
| Release HTTP 限制 | 通过 | Release 配置运行 `debugLoopbackIsRestricted`，字面回环 HTTP 也被拒绝 |
| 共享 Xcode 工作区／scheme | 通过 | `AzureFishNetworking` 的 macOS `test` 为 TEST SUCCEEDED；协议 2、网络 8、API 9 项实际执行，真实服务项按默认配置跳过 |
| 协议同步与锁文件 | 通过 | `sync-server-protocol.py --check`；客户端生成文件与服务端原样一致，精确运行库 1.38.1；无客户端 .proto 或生成插件 |
| 文档与静态检查 | 通过 | 本次文件本地链接、空白、Python／XML 语法及 `git diff --check` |
| 完整 AzureFish App 编译／页面联调 | 未执行 | 包尚未链接到 App target，未修改 App 工程、启动路由或 UI |
| 模拟器运行／真机／人工视觉 | 未执行／不适用 | 本轮完成编译和 macOS 网络运行验证，没有 UI 变更，未在 iOS 设备运行 |
| 真实账号 HTTPS／Apple／Keychain／SQLCipher | 未执行 | 本轮没有这些实现，不能将网络包测试当作对应验收 |

Xcode 测试过程包含“无 AppIntents.framework，跳过 metadata extraction”的工具提示；本包无 App Intents 能力。XCTest 的 `Executed 0 tests` 不是本轮判定依据，已核对随后 Swift Testing 的实际用例输出和显式跳过项。

## 核心运行场景

- 登录与刷新响应验证 environment、user、device、session、refresh generation 和绝对截止；资料不接受其他用户响应。
- 已准备操作禁止跨环境／账号／session 或使用更低代次凭据；同一 session 的较新 Bearer 可重放原资料字节。
- 业务 401、HTML 代理错误、成功响应 MIME 错误、截断 Protobuf、429 和未知业务码分类；不隐式刷新或安装会话。
- 原始 `operation_id`、optional 空简介、缺失昵称、重复请求体保持不变；密码正文不出现在默认描述中。
- 实际后端闭环覆盖注册及结果恢复、密码登录、资料更新、刷新及结果恢复、刷新后资料重试、读取、退出重试与退出后 401。测试服务完成后已停止。

## 复现命令

从 AzureFish 根目录执行，首次需要联网获取 SwiftProtobuf：

```sh
swift test --package-path SharePackage/AzureFishProtocol -j 4
swift test --package-path SharePackage/AzureFishNetwork -j 4
swift test --package-path SharePackage/AzureFishAPI -j 4
swift test --package-path SharePackage/AzureFishNetwork -c release -j 2 --filter debugLoopbackIsRestricted

xcodebuild -workspace AzureFishNetworking.xcworkspace -scheme AzureFishAPI \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/AzureFishNetworking-DD \
  IPHONEOS_DEPLOYMENT_TARGET=15.0 CODE_SIGNING_ALLOWED=NO build

xcodebuild -workspace AzureFishNetworking.xcworkspace -scheme AzureFishNetworking \
  -destination 'platform=macOS' -derivedDataPath /tmp/AzureFishNetworking-DD \
  CODE_SIGNING_ALLOWED=NO test

# 另行启动本机虚构数据 AzureFishServer 后：
AZUREFISH_API_LIVE_TEST=1 swift test --package-path SharePackage/AzureFishAPI \
  --filter LiveAccountAPITests -j 4

python3 Scripts/sync-server-protocol.py --server AzureFishServer --check
```

包测试与 App 验收分开记录；框架存在并不表示凭据已进入 Keychain、单次刷新协调已实现或登录 UI 已接通。

## 服务端目录迁移复核（2026-09-24）

服务端已从仓库外的同级目录移至仓库根目录 `AzureFishServer/`，仍是独立 Swift Package。迁移时 22 个文件逐一校验 hash 一致；之后仅更新服务端 README 和 AGENTS 的位置说明，业务源码、协议和依赖锁定未变。

- 通过：旧目录已移除、新目录文件完整，19 个相关文档链接有效，协议快照 `--check` 和 `git diff --check`。
- 通过：同步脚本对嵌套仓库中未跟踪、已暂存、已提交和已修改的协议来源分别校验；未提交内容不再误用父仓库 HEAD。
- 通过（迁移后重新执行）：服务端 Debug 完整编译及 14 项集成测试；客户端协议 2 项、网络 8 项、账号 API 模拟测试 9 项；账号 API 的 1 项真实 HTTP 联调另行显式启用并通过。
- 通过：从 `AzureFishServer/.build/debug/AzureFishServer` 启动新编译程序，Python Protobuf 脚本完成健康检查、注册与重复注册、登录、资料读改、刷新重试、退出和退出后 401；Swift 客户端通过真正 URLSession 完成账号闭环。使用独立临时数据库和随机测试密钥，结束后服务已停止、临时数据已清理。
- 通过：上述构建／测试无编译警告，服务端依赖锁文件保持不变。API 默认测试输出包含 1 项跳过用例，已按 9 项实际模拟测试统计；单独联调运行确认 1 项实际执行。
- 本次未重新执行：iOS 模拟器目标编译、Release 限制及共享 Xcode 工作区测试；上文对应记录属于迁移前结果。App／模拟器运行、真机和真实账号 HTTPS 仍未执行。

本次命令为上文三个 `swift test --package-path SharePackage/… -j 4`、`swift test --package-path AzureFishServer -j 4`、`PROTOC=/private/tmp/azurefish-protoc/bin/protoc python3 AzureFishServer/Scripts/smoke-test.py`，以及启用 `AZUREFISH_API_LIVE_TEST=1` 的 `swift test --package-path SharePackage/AzureFishAPI --skip-build --filter LiveAccountAPITests`。服务端通过环境变量指定临时数据目录和权限为 0600 的随机密钥文件，不使用已有账号数据。

运行日志保存在本机 `/private/tmp/azurefish-relocated-{server,protocol,network,api,live}-tests.log`；这些日志是临时验证证据，不作为构建输入。
