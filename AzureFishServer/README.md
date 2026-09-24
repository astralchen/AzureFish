# AzureFishServer

AzureFish 的独立 Swift 6＋Vapor 服务端，位于仓库根目录的 `AzureFishServer/`。首期实现密码账号 HTTP＋Protobuf 接口，持久化采用 Fluent SQLite。客户端不依赖本工程目录构建，不共享数据库。

**当前仅供本机虚构账号开发联调。** 服务固定监听 `127.0.0.1:8080`，要求显式启用测试数据模式；不提供生产、局域网真机或真实账号运行模式。Apple、头像、改密、删除账号与 IM 尚未实现，iOS App 仍使用原来的本地聊天演示。

## 本机启动

需要 Swift 6.3 工具链、Git、Python 3；首次构建会下载 Swift Package。macOS 使用 Xcode 的 Swift，当前验证版本见[验证记录](Documentation/validation.md)。

```sh
cd /你的路径/AzureFish/AzureFishServer
sh Scripts/run-local.sh
```

脚本在忽略目录 `.local/` 生成随机 32 字节密钥（权限 0600），数据库放在 `.local/test-data/`（目录权限 0700）。再次启动复用数据和密钥；原库缺钥或钥不匹配时停止，不覆盖原数据。Ctrl-C 停止服务。同一数据目录只允许一个进程。

手工运行时设置 `AZUREFISH_ALLOW_LOCAL_TEST_DATA=1`、绝对路径 `AZUREFISH_DATA_DIRECTORY`、绝对路径 `AZUREFISH_KEY_FILE`；密钥文件必须是 32 字节原始随机数据、权限 0600。不要将密钥或 `.local` 放入 Git、同步盘或共享目录。可执行程序不接受更改监听地址的命令行参数。

## 已实现接口

| 方法与路径 | 请求 | 响应 |
| --- | --- | --- |
| `GET /health` | 无 body | `HealthResponse` |
| `POST /v1/auth/register` | `RegisterRequest` | `AuthResponse`，201 |
| `POST /v1/auth/login` | `LoginRequest` | `AuthResponse` |
| `POST /v1/auth/refresh` | `RefreshRequest` | `AuthResponse` |
| `POST /v1/auth/logout` | `LogoutRequest`＋Bearer | `EmptyResponse` |
| `GET /v1/me` | Bearer，无 body | `UserProfile` |
| `PATCH /v1/me` | `UpdateProfileRequest`＋Bearer | `UserProfile` |

所有响应（含错误）为 `application/protobuf`。详情见[网络协议](Documentation/protobuf-contract.md)，字段编号唯一来源为 [Protos/azurefish.proto](Protos/azurefish.proto)。不要通过浏览器或 JSON 请求推断二进制接口行为。

## 验证和协议生成

```sh
swift test -j 4
# 安装官方 protoc 后；另一终端保持服务运行
python3 Scripts/smoke-test.py
# 仅在修改 .proto 或生成器版本时执行
sh Scripts/generate-protocol.sh
```

生成脚本支持 `PROTOC=/绝对路径/protoc`，使用锁定依赖中的 `protoc-gen-swift`。生成的 Swift 文件和 `Protos/generation.json` 纳入版本管理；普通构建无需 protoc。后续 iOS 接入复制生成产物和版本清单，不能复制／另行维护协议源。`Package.resolved` 锁定依赖，升级需重新生成、审查和测试。

## 架构与后续顺序

- `Sources/Server`：配置、错误与二进制 HTTP 边界、账号服务、数据库模型及迁移；`Sources/Run`：可执行入口。
- `Tests/ServerTests`：Swift Testing 的真实 SQLite＋内存 HTTP 集成测试，临时目录和随机密钥逐用例隔离。
- 写事务与认证读取经过同一个有界异步锁，避免 SQLite 并发刷新和重复注册竞态；文件锁禁止多个实例共享同一数据库。这是首期单实例设计，不能直接扩展为多节点。
- 下一阶段先补 HTTPS、部署密钥管理与轮换／恢复、持久化分布式限流及数据清理策略，再开放真实账号；随后实现 Apple、头像、账号安全和 iOS 接入。IM 独立推进。

安全边界见[安全说明](Documentation/security.md)，本次测试证据与未验证项见[验证记录](Documentation/validation.md)。
