# 首期密码账号接口验证

日期：2026-09-24。环境：macOS、Intel x86_64、Apple Swift 6.3.2；Vapor 4.122.2、Fluent 4.13.0、Fluent SQLite Driver 4.9.0、SwiftProtobuf 1.38.1、Swift Crypto 3.15.1。完整版本与 revision 以 `Package.resolved` 为准。

## 首次实现结果（迁移前）

| 验证项目 | 结果 | 证据与边界 |
| --- | --- | --- |
| 依赖解析／服务端 Debug 编译 | 通过 | `swift test -j 4` 构建服务端可执行程序及测试；无最终编译警告 |
| Swift Testing 集成测试 | 通过 | 14 项，0 失败；使用真实临时 SQLite、随机密钥、内存 HTTP，测试密码 cost 4 |
| 本机真实 HTTP 联调 | 通过 | `sh Scripts/run-local.sh` 成功监听 127.0.0.1:8080；`Scripts/smoke-test.py` 完成健康检查、注册及重复注册、密码登录、资料读改、刷新响应重试、退出和退出后 401；实际密码 cost 12 |
| 协议生成复现 | 通过 | protoc 29.3＋锁定版本 protoc-gen-swift 重新生成后与提交产物逐字一致；schema hash 已记录 |
| Shell／Python 静态检查 | 通过 | `sh -n` 和 Python AST 解析；未安装 Python 第三方依赖 |
| 源码／文档检查 | 通过 | 本次文件空白和本地链接检查；客户端 `git diff --check` |
| 客户端编译／单元／模拟器 UI／人工视觉／真机 | 不适用 | 本轮没有修改客户端代码或 UI |
| 客户端到服务端联调 | 未执行 | iOS 网络和认证模块仍未接入 |
| Linux／Release 部署／HTTPS／真实账号／真实 Apple | 未执行 | 首期没有开放这些运行路径 |
| SQLCipher／Keychain／生产密钥轮换与灾难恢复 | 未执行 | 未将服务端字段加密当作客户端存储或生产安全验收 |

## 自动化覆盖

1. 注册自动登录、账号规范化、重复注册结果、密码登录及重试、读取资料、退出重试和会话隔离。
2. 刷新轮换、绝对期限不延长、同操作恢复、旧代结果忽略，以及旧 refresh 换 ID 重放后撤销确实持久化。
3. 并发重复刷新只产生一个代次；并发重复注册只产生一个用户和会话。
4. 资料字段 presence、显式清空简介、版本冲突、跨账号操作 ID 冲突，刷新后重试原资料操作。
5. 密码错误与未知账号统一业务码，写操作 ID 复用冲突，账号名占用。
6. access／refresh 到期、10 分钟恢复窗口到期后不重复执行认证动作。
7. 错误 MIME、非法 Protobuf、无效 Accept、未知路由、16 KiB 限制、缺少凭据。
8. 密码字节上限、空昵称、账号限流和 Retry-After。
9. 服务重启后资料和会话可读，刷新原响应可恢复。
10. 同一数据库的第二个所有者被拒绝；密文篡改、跨记录替换、错误密钥失败；原钥仍能重新打开；数据库及现存 sidecar 中没有抽样密码／资料／令牌明文。

本轮测试没有证明生产可用性。限流仍为进程内，记录没有定时物理清理，数据库与密钥仅用于独立的虚构数据目录。后续能力和上线门槛见[安全说明](security.md)。

## 移入 AzureFish 仓库后的复测（2026-09-24）

在 AzureFish 仓库根目录执行 `swift test --package-path AzureFishServer -j 4`：新目录完整 Debug 编译成功，14 项 Swift Testing 集成测试全部通过，无编译警告；`Package.resolved` 未改变。

使用本目录中新编译的 `.build/debug/AzureFishServer`、独立临时数据库及随机密钥启动回环服务。`Scripts/smoke-test.py` 真实 HTTP 闭环通过；另行显式运行 AzureFishAPI 的 `LiveAccountAPITests`，1 项真正 URLSession 账号闭环通过。联调结束后服务已停止，临时数据库和密钥已清理。

客户端协议包 2 项、网络包 8 项、账号 API 模拟测试 9 项也已重新通过，协议同步 `--check` 通过。命令、日志及边界见[客户端迁移复核](../../Documentation/Networking/validation.md#服务端目录迁移复核2026-09-24)。这些结果属于 macOS 本机虚构账号验证，App UI、iOS 运行、真实账号 HTTPS 与 Apple 登录仍未执行；本次没有重新生成协议。

## proto 注释与 Swift 名称调整（2026-09-26）

权威 proto 补充中文消息／字段注释，设置空 `swift_prefix`；重新生成 Swift 并更新服务端调用后，`swift test --package-path AzureFishServer -j 4` 编译及 14 项集成测试通过。生成工具为 SwiftProtobuf 1.38.1 和其自带 protoc 35.1。

protoc 描述符除 Swift 命名选项外与原协议完全一致，消息／字段编号／类型及 optional presence 未改变；生成代码除类型重命名和注释外无其他变化。客户端插件产物与本目录生成文件一致，客户端包测试及 App 编译通过，详情见[本次插件验证](../../Documentation/Networking/validation.md#proto-插件生成与-swift-短名称2026-09-26)。本次未重新执行真实 HTTP 或真实账号联调。

## 文本 IM 接口实施与验收（2026-09-27，媒体扩展前的记录）

环境仍为 Intel macOS、Apple Swift 6.3.2 与锁定依赖；未修改 Package.resolved。权威协议使用 SwiftProtobuf 1.38.1、protoc 35.1 生成。旧账号 proto 内容保持不变，只追加 IM 消息。

| 验证项目 | 本次结果 | 证据与限制 |
| --- | --- | --- |
| 服务端 Debug 编译 | 通过 | `swift test -j 4` 完整构建，无最终编译警告 |
| Swift Testing 集成与网络测试 | 通过 | 显式开启 HTTP smoke 后共 28 项、0 失败：14 项原账号＋14 项 IM（含 1 项真实网络） |
| 真实 TCP HTTP／WebSocket | 通过 | `Scripts/smoke-test.py` 由 `realSocketSmoke` 在随机回环端口执行；临时独立数据库／随机密钥，bcrypt cost 4 |
| 协议再生成 | 通过 | 同一 protoc 与锁定生成器输出逐字一致；schema SHA-256 匹配 |
| 客户端协议同步 | 通过 | `Scripts/sync-server-protocol.py --server AzureFishServer --check`；仅同步 proto 与清单，不提交客户端生成 Swift |
| 客户端协议包独立编译／测试 | 通过 | `SharePackage/AzureFishProtocol` 内 `swift test -j 4`：3 项通过；官方插件生成产物与服务端逐字一致；SwiftPM 对既有 `swift-protobuf-config.json` 报 unhandled-file 提示，不影响生成或测试 |
| 文档／静态检查 | 通过 | 本地链接、Python AST、Swift 空白、旧账号协议前缀一致性、`git diff --check` |
| App 编译／单元／模拟器 UI／人工视觉／真机 | 未执行 | 本轮只实现服务端与同步协议，不宣称 App 聊天已接入 |
| HTTPS／WSS／真实账号／Linux／多节点／生产容量 | 未执行 | 保留单实例回环虚构数据限制 |
| 媒体字节／对象存储／APNs／端到端加密 | 不适用 | 本轮未实现，需求中单独规划 |

本次覆盖：并发私聊解析、重复／不同消息并发发送、双重身份冲突、账号／设备隔离、群主权限与版本冲突、成员离开／重入、旧成员资料冻结、转让／解散、授权历史缺口、固定分页上界与边界失效、单调阅读与送达、固定回执受众与明细快照、撤回终态与旧发送重试、事件分页与跨账号／篡改游标拒绝、固定会话快照与基线、快照过期、重启／token 刷新恢复、原账号库增量迁移、消息密文交换检测与事务回滚、抽样落盘无正文、52 条 64 KiB 文本的响应字节预算与不漏页。

网络 smoke 覆盖原账号闭环、私聊创建、消息发送／幂等、历史、撤回、建群／解散、快照、WebSocket 二进制初始／变更提示、提示后 HTTP 增量、退出后连接关闭。首次真实网络运行暴露回调注册不在 WebSocket event loop 的问题，修复后全量网络测试通过；默认 `swift test` 不启用外部 Python smoke，会跳过该 1 项。

复现（将 `PROTOC` 指向本机 protoc）：

```sh
cd AzureFishServer
AZUREFISH_RUN_HTTP_SMOKE=1 PROTOC=/绝对路径/protoc swift test -j 4
# 已启动本机服务时也可单独执行；默认使用回环 8080
PROTOC=/绝对路径/protoc python3 Scripts/smoke-test.py
```

本次没有停止或重启用户已有的 8080 服务，没有读写 `.local` 数据；网络测试的临时服务在结束后关闭并清理数据。结果只证明本机虚构数据闭环，不代表生产可用性。未读扫描性能、密钥轮换、物理擦除／备份、事件截断恢复仍需专项验收。


## 媒体后台实施与验收（2026-09-27）

本轮扩展后台媒体接口、macOS 独立处理进程和客户端协议副本，没有实现 iOS 上传队列、加密媒体缓存或聊天 UI。媒体类型、状态、错误与客户端恢复约定见 [媒体契约](media-contract.md)，磁盘格式见 [媒体存储](media-storage.md)。结构化结果与测试名称保存在 [本次验证摘要](media-validation-2026-09-27.json)。

| 验证项目 | 本次结果 | 证据与限制 |
| --- | --- | --- |
| 服务端与独立媒体工作进程 Debug 编译 | 通过 | Swift 6，锁文件未改变，最终构建没有新增编译警告 |
| 服务端全量回归 | 通过 | 40 项、8 个 suite、0 失败；包含原账号、文本 IM 和媒体测试 |
| 全媒体真实 HTTP | 通过 | 图片、GIF、视频、CAF 语音、普通文件、Live Photo：上传、就绪、发送、历史同步、授权下载；原件摘要一致；混排组保持顺序 |
| 权限、撤回与引用 | 通过 | 跨账号引用拒绝、跨会话引用拒绝、群入群前／离开期间下载拒绝、旧发送重试不恢复附件、旧授权失效、多消息引用保留、最后引用回收 |
| 分块与恢复 | 通过 | 乱序、重复、冲突、完成重试、凭据刷新、重新登录、数据库重启续传、未提交密文及临时明文启动清理 |
| 媒体失败处理 | 通过 | 畸形图片、声明 MIME 伪造、Live Photo 缺件／错配、超限、工作进程异常退出／超时、资源密钥缺失；不伪装 ready |
| 密文与存储故障 | 通过 | 错钥、上传者／用途替换、分块重排／截断／替换；数据库写入失败注入不提交分块且移除新密文；存储边界注入容量不足及写失败，修复后可继续原上传 |
| 大文件与内存 | 通过 | 536,870,875 字节（512 MiB − 37）原件，128 分块，中途刷新凭据与补传，发送后逐段 Range 下载，整件 SHA-256 相同。最终全量测试进程驻留基线 75,284,480、采样峰值 106,610,688 字节；该进程同时包含测试客户端，子媒体进程不计入此指标 |
| 慢传输与取消 | 通过 | Python 慢上传期间账号／文本控制请求合计小于 2 秒；取消后未提交分块，回收等待现有访问结束 |
| HTTP 下载语义 | 通过 | 跨分块 Range、后缀／开放尾段、206／416、If-Range 回退、连续 HEAD 返回完整长度且不占用下载名额 |
| 协议再生成与客户端同步 | 通过 | 权威 schema hash、同步检查、服务端再生成与客户端官方插件产物逐字一致；旧字段编号保留 |
| 客户端协议包独立编译／测试 | 通过 | 4 项；包含媒体追加字段编号、元数据及未知字段转存 |
| 文档／静态检查 | 通过 | 本地链接、Python 语法、规则一致性及 git diff --check |
| 物理磁盘耗尽／断电恢复 | 未执行 | 本轮使用存储边界故障注入，没有填满开发者磁盘或执行断电实验 |
| App 编译／模拟器／人工视觉／真机 | 未执行 | 本轮仅后台和协议；不能据此描述 iOS 媒体已联网 |
| 生产 HTTPS/WSS／真实账号／Linux／对象存储 | 未执行 | 仍保持本机虚构数据边界 |
| 病毒扫描／内容审核 | 未执行 | 非本期范围；普通文件不执行、不解压、不生成复杂预览 |

容量测试首次发现完整性校验循环的 Foundation 桥接临时对象积累，进程峰值约 1.2 GiB；在 IO 和每个校验分块增加 autoreleasepool 后复测通过。单独容量复测的驻留基线为 55,422,976、采样峰值为 88,317,952 字节。HEAD 回归另发现 Response 初始化覆盖 Content-Length，调整为初始化后设置真实表示长度后，最终 40 项全量测试通过。以上指标为本机测试采样，不代表生产容量或媒体解码进程的峰值保证。

复现：

```sh
cd AzureFishServer
AZUREFISH_RUN_MEDIA_CAPACITY=1 AZUREFISH_RUN_HTTP_SMOKE=1 PROTOC=/绝对路径/protoc swift test -j 4
# 默认 swift test 跳过大文件和外部账号/IM smoke；媒体 HTTP 测试仍会执行。
```

在仓库根目录执行 `python3 Scripts/sync-server-protocol.py --server AzureFishServer --check`；客户端协议包在 `SharePackage/AzureFishProtocol` 执行 `swift test -j 4`。`Scripts/media-slow-transfer.py` 由集成测试通过 stdin 注入临时凭据，不打印凭据。所有媒体样例随服务端测试提供，来源记录在测试 Fixtures/README.md。

未停止或重启用户已有的 8080 服务，未读写 `.local` 原数据库与密钥。临时服务、数据库与媒体由测试关闭和清理。没有执行提交、推送或部署。

## 2026-09-27 原版聊天接入的协议扩展

`swift test -j 4` 通过 45 项／12 个 suite。新增 `RichMessageTests` 验证有序语义格式、组合 emoji／阿拉伯文、链接接受规则、请求重放、历史和撤回清理。`AZUREFISH_RUN_CLIENT_CHAT=1 swift test -j 4 --filter ClientChatHarnessTests` 通过隔离随机回环端口联调，客户端 `IndependentChatTests` 实际通过；未接触现有 8080 服务或真实账号。

客户端聊天包 16 项测试通过；协议同步脚本 `--check` 通过。UI 与权限边界见[本次接入记录](../../Documentation/Design/Chat/original-ui-restoration.md)。

## 2026-09-28 好友通过双向提醒

`AZUREFISH_RUN_HTTP_SMOKE=1 swift test -j 4` 本轮发现 48 项测试，实际通过 45 项，3 项显式启用的客户端 harness／大文件测试跳过。新增回归覆盖双方未读、独立已读、重复接受、删除后重加、旧操作重试、事务失败回滚、会话容量限制、重启及系统消息发送／撤回／回执权限。

随机回环端口 HTTP smoke 通过：双方固定快照及历史包含同一系统提示，申请人阅读后接受方仍未读；原消息、群聊、实时提示与退出流程继续通过。记录为 `/tmp/azurefish-friend-server-final.log`。没有修改或重启既有 8080 服务，没有为旧好友补历史提示。客户端、设计与各类运行验证边界见[双向提醒交付记录](../../Documentation/Design/Chat/friendship-notice.md)。
