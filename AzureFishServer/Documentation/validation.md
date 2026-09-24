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
