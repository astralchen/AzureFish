# 本地 SPM 验证记录

日期：2026-09-24。工具链：Apple Swift 6.3.2；三个包均声明 `swift-tools-version: 6.3`、Swift 6 语言模式，最低 iOS 15／macOS 12。测试运行平台为 Intel macOS。

## 本地包阶段结果（2026-09-24）

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

## 客户端工程接入验证（2026-09-26）

`AzureFish.xcodeproj` 已通过 `XCLocalSwiftPackageReference` 引用 `SharePackage/` 下的三个包，并把 AzureFishProtocol、AzureFishNetwork、AzureFishAPI products 加入 AzureFish target 的依赖及 Frameworks 链接阶段。测试辅助 product 和服务端未加入 App 依赖。

| 验证 | 状态 | 本次证据与边界 |
| --- | --- | --- |
| 工程配置、相对路径与锁文件 | 通过 | project.pbxproj 格式与 target 引用检查；现有远程依赖 revision 未变，仅新增 SwiftProtobuf 1.38.1 |
| 完整 AzureFish App 模拟器编译／链接 | 通过 | Xcode 26.5、Swift 6.3.2，Debug，arm64 和 x86_64，最低 iOS 15；`BUILD SUCCEEDED` |
| 三个模块导入与公开类型 | 通过 | 使用本次 App 构建产物，Swift 6 模式、iOS 15 模拟器 arm64／x86_64 分别 typecheck：AccountAPI、HTTPTransport、Azurefish_V1_HealthResponse |
| 文档与空白检查 | 通过 | 接入状态／使用说明及相关文档链接检查，`git diff --check` |
| 单元／组件运行、真实 HTTP 联调 | 未执行 | 本次仅修改工程依赖及文档，包的运行测试以此前日期记录为准 |
| 模拟器 UI／真机／人工视觉 | 未执行 | 未修改或接通登录页面、账号状态及 Keychain；构建不代表运行验收 |

复现命令（仓库根目录）：

```sh
xcodebuild -workspace AzureFish.xcworkspace -scheme AzureFish \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/AzureFish-SPM-DD -jobs 4 \
  CODE_SIGNING_ALLOWED=NO build
```

构建日志：`/private/tmp/azurefish-app-spm-build.log`。唯一 warning 为未依赖 AppIntents.framework 而跳过 metadata extraction；未发生 Swift 编译或链接错误。导入检查使用临时 Swift 文件，未向 App 添加占位代码或启动网络请求。

## proto 插件生成与 Swift 短名称（2026-09-26）

本节为当前生成方式；此前“提交生成 Swift／不使用插件”的记录描述当时实现。客户端现在保存服务端 proto 副本与插件配置，构建时由 SwiftProtobufPlugin 生成公开类型，不再提交客户端 `.pb.swift`。SwiftPM 需要一个只含注释的 Swift 占位文件识别 target，该文件不包含协议实现。

权威 proto 的所有消息和字段已补充中文注释，并设置 `option swift_prefix = "";`。Swift 类型使用 `RegisterRequest`、`AuthResponse` 等原名；网络包名仍为 `azurefish.v1`。业务与协议资料同名处使用 `AzureFishProtocol.UserProfile` 限定原始协议类型。

| 验证 | 状态 | 本次证据与边界 |
| --- | --- | --- |
| SwiftPM 自动生成与协议测试 | 通过 | 移除源码中的生成 Swift 后，插件实际调用自带工具；3 项测试验证短 Swift 名称保留原网络消息名、optional／Int64、未知字段往返 |
| 本地包共享工作区运行 | 通过 | `TEST SUCCEEDED`；协议 3、网络 8、账号 API 模拟测试 9 项（业务 401 含 4 组参数）；真实服务 1 项按默认配置跳过 |
| 服务端编译与集成测试 | 通过 | 同步生成短类型名后，14 项真实临时 SQLite／内存 HTTP 测试通过 |
| 完整 AzureFish App 模拟器编译／链接 | 通过 | 官方插件自动生成，`BUILD SUCCEEDED`；arm64／x86_64，最低 iOS 15 |
| 生成与契约一致性 | 通过 | 客户端插件产物与服务端生成文件逐字一致，短名称及中文 Swift 文档注释存在；protoc 描述符除 Swift 前缀选项外一致，服务端生成代码除命名和注释外一致 |
| 同步脚本回归 | 通过 | 正常副本检查、客户端漂移检测与恢复、服务端 schema hash 不匹配拒绝、残留 `.pb.swift` 拒绝 |
| 依赖、资源与文档检查 | 通过 | 已有依赖 revision 未变；proto／配置未复制到 App 资源；文档链接、脚本语法及 `git diff --check` |
| 真实 HTTP 联调／App UI／真机／真实账号 | 未执行 | 本次没有重新执行这些运行路径，历史联调结果不代替本次验收 |

工具链为 Swift 6.3.2／Xcode 26.5，SwiftProtobuf 精确版本 1.38.1，自带 protoc 为 35.1。首次构建会编译生成工具；无需手工安装或配置系统 protoc。SwiftPM 对插件所需 `swift-protobuf-config.json` 有 unhandled-file 警告；该文件必须保留供插件读取，没有复制为运行资源。Xcode 另有未依赖 AppIntents.framework 而跳过 metadata extraction 的提示；没有编译／链接错误。

复现命令（仓库根目录）：

```sh
swift test --package-path SharePackage/AzureFishProtocol -j 4
swift test --package-path AzureFishServer -j 4
python3 Scripts/sync-server-protocol.py --server AzureFishServer --check
xcodebuild -workspace AzureFishNetworking.xcworkspace -scheme AzureFishNetworking \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/AzureFish-SPM-DD \
  -jobs 4 CODE_SIGNING_ALLOWED=NO test
xcodebuild -workspace AzureFish.xcworkspace -scheme AzureFish \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/AzureFish-SPM-DD \
  -jobs 4 CODE_SIGNING_ALLOWED=NO build
```

日志位于 `/private/tmp/azurefish-proto-plugin-tests.log`、`azurefish-proto-plugin-workspace-tests.log`、`azurefish-server-short-proto-tests.log` 和 `azurefish-app-proto-plugin-build.log`。本次 API 测试证据取自共享 Xcode 工作区的实际运行输出。

## 客户端风格注释补全（2026-09-26）

三个包按客户端中文 DocC 规范补全调用契约，覆盖参数、返回值、默认值、`nil`、错误、取消、重试及会话状态职责。协议注释在服务端权威 `.proto` 中维护，重新生成服务端类型后同步客户端副本与来源清单；客户端仍由构建插件生成 Swift。

| 验证 | 状态 | 本次证据与边界 |
| --- | --- | --- |
| 公开声明与协议注释覆盖 | 通过 | 手写 Swift 的 153 个公开声明／枚举成员具有中文文档注释；proto 的 10 个消息、38 个字段具有中文注释 |
| 签名与逻辑保持一致 | 通过 | 对比本次注释修改前的 13 份源码快照，非注释 token 一致；多成员枚举 case 的换行按相同声明规范化后比较 |
| 协议与生成一致性 | 通过 | 修改前后不含源码注释的协议描述符逐字一致；客户端副本通过官方锁定工具生成的 Swift 与服务端产物一致；同步脚本 `--check` 通过 |
| Swift 语法与空白检查 | 通过 | 三个包及网络测试辅助模块执行 Swift 6 `-frontend -parse`；`git diff --check` 通过。语法解析不等于编译或类型检查 |
| 编译、单元／组件测试、接口运行 | 未执行 | 本次为注释更新，未重复运行；前述编译与运行记录属于各自独立的验证阶段 |
| 模拟器 UI、人工视觉、真机 | 不适用 | 本次未变更界面及运行行为 |

## 启动参数网络日志（2026-09-26）

`HTTPClient` 已接入 Debug 专用的 `-AzureFishNetworkLogging true` 启动开关，默认关闭，Release 始终关闭。使用系统 debug 日志，subsystem 为 `AzureFish.Network`、category 为 `HTTPClient`；公开接口及原有重试、取消和错误传播契约保持不变。配置与字段说明见 [AzureFishNetwork README](../../SharePackage/AzureFishNetwork/README.md#调试日志)。

| 验证 | 状态 | 本次证据与边界 |
| --- | --- | --- |
| 网络包 Debug 编译与测试 | 通过 | 18 项测试：原有 8 项及新增 10 项；包含原生 URLSession 虚构数据回环验证 |
| 网络包 Release 编译与测试 | 通过 | 17 项测试；原生回环测试仅在 Debug 编译，启动参数 true 在 Release 返回关闭 |
| 日志事件与脱敏回归 | 通过 | 成功／HTTP 503、重试、最终传输失败、校验失败、超限、重试等待失败及取消、提前取消；未知错误不输出描述，虚构正文、凭据、URL、业务操作 ID 未进入日志；关闭时消息不求值且不采集时间 |
| API 模拟回归 | 通过 | Xcode 共享工作区仅运行 AzureFishAPITests，9 项模拟测试通过（业务 401 含 4 组参数）；1 项真实 HTTP 流程按默认配置跳过 |
| 实际系统日志开关 | 通过 | 使用当前源码编译的临时 Debug／Release 程序及虚构 transport，通过 log stream 按 subsystem、category 和进程筛选；Debug true 捕获 send／response 两条事件，Debug 默认／false 与 Release true 均为零条；输出不含虚构敏感数据 |
| 文档与静态检查 | 通过 | README 配置说明及本地链接、`git diff --check`；未修改工程 Scheme 开关或依赖锁文件 |
| App 编译、iOS 运行、真机、真实账号／服务联调 | 未执行 | 本次运行证据来自 macOS 包测试和虚构传输，不代表 App 或真实服务验收 |

工具链为 Swift 6.3.2／Xcode 26.5。首次沙箱运行因用户编译缓存写权限失败，通过构建权限重新运行后通过；SwiftPM Debug／Release 构建没有编译警告，Xcode 有未依赖 AppIntents.framework 而跳过 metadata extraction 的工具提示。

复现命令（仓库根目录）：

```sh
swift test --package-path SharePackage/AzureFishNetwork -j 4
swift test --package-path SharePackage/AzureFishNetwork -c release -j 4
xcodebuild -workspace AzureFishNetworking.xcworkspace -scheme AzureFishNetworking \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/AzureFish-SPM-DD \
  -jobs 4 CODE_SIGNING_ALLOWED=NO -only-testing:AzureFishAPITests test
```

本机日志：`/private/tmp/azurefish-network-logging-debug.log`、`azurefish-network-logging-release.log`、`azurefish-network-logging-api.log`。临时系统日志检查源码、输出及进程映射位于 `/private/tmp/azurefish-network-log-smoke/`，不作为构建输入；检查结束后日志订阅及虚构请求进程均已退出。
