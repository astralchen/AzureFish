# 密码账号接口契约 v1

本文件解释实现行为，消息、字段类型和编号的唯一来源是 [azurefish.proto](../Protos/azurefish.proto)。包名 `azurefish.v1`；生成清单记录 schema SHA-256 与生成器版本。删字段时保留原编号为 `reserved`，不重新分配已发布编号。

## 传输与通用规则

- 当前只有虚构数据回环 HTTP。真实账号、Apple、真机与部署必须先实现 HTTPS，不关闭证书校验；未来 IM 使用 WSS。
- 请求／响应为 `application/protobuf`，GET 无 body，写请求最大 16 KiB；可接受的 `Accept` 是 Protobuf 或兼容通配符。认证头为 `Authorization: Bearer <access_token>`。
- 响应统一 `Cache-Control: no-store`，服务端为每次调用生成 `X-Request-ID`；错误体 `ApiError.request_id` 与头一致，不回显未经信任的请求 ID 或正文。业务错误仅提供稳定 code／field，由客户端翻译。
- 时间戳均为 Unix 毫秒。`operation_id` 和 `device_id` 必须是 36 字符 UUID；设备 ID 为安装标识，不当作可信硬件证明。服务端返回的 UUID 使用小写。
- 写动作须生成新 operation ID；同一动作重试必须复用原 ID 与完全相同的 Protobuf 字节。未知字段也参与指纹，不能解码后重新序列化作为重试请求。

## 路由与账号规则

路由表见[入口](../README.md#已实现接口)。注册自动创建会话，重试同样返回 201。登录创建新会话，不撤销其他会话。退出只撤销当前会话。

账号名去除首尾空白后转小写，限制 3～32 个 ASCII 字符 `[a-z0-9_]`，唯一且不能通过资料接口修改。不按邮箱合并。密码不 trim、不规范化，至少 12 个 Swift Character、最多 72 个 UTF-8 字节，禁止 NUL；上限用于避免 bcrypt 静默截断，不要求特定字符组合。登录沿用相同校验。

昵称必填，最多 64 个 Swift Character，不能全空白；简介最多 500 个，允许清空。二者保留原值，拒绝除换行以外的控制字符。应用语言不会改变账号、密码或协议值。

`PATCH /v1/me` 至少包含一个 optional 字段；未传保留原值，显式空简介表示清空，空昵称无效。必须提交当前 `expected_profile_version`，成功后递增。版本冲突返回 409，客户端保留编辑内容、读取最新资料后由用户决定，不能自动覆盖。

## 会话、刷新与重试

- 令牌为独立的 256 位随机不透明值。access 最长 15 分钟，refresh 从会话建立起绝对 30 天，刷新不延期；access 同样不得超过 refresh 截止。`refresh_generation` 从 1 开始，每次成功刷新加 1。
- 每次刷新同时替换 access／refresh，旧 access 立即失效。客户端每个 session 只允许一个共享刷新任务。
- 成功写动作保存加密结果，恢复窗口 10 分钟（受会话绝对截止限制）。注册、登录、刷新在原会话有效且代次仍相同时可重放相同结果，支持服务重启恢复。
- 操作 ID 全局唯一。已有 ID 搭配不同路由／会话或不同请求字节返回 `OPERATION_CONFLICT`，不执行业务。资料及退出重试作用域绑定 session，不绑定某个 access，因此普通资料重试可跨刷新。
- 已完成的刷新以相同操作 ID 重试，若会话又推进到更高代次，返回 `REFRESH_SUPERSEDED`，不撤销新会话。注册／登录旧结果的代次失效返回 `AUTH_ATTEMPT_EXPIRED`。
- 消费过的 refresh 搭配其他操作 ID 使用，撤销整个 session，提交撤销事务后返回 `REFRESH_REPLAY`。无法识别、已撤销或已过期的令牌返回 `UNAUTHENTICATED`。
- 恢复窗口过期不会重新执行已知动作；认证返回 `AUTH_ATTEMPT_EXPIRED`，资料／退出返回 `OPERATION_RESULT_EXPIRED`。结果和去重记录当前保留在加密／摘要形式的本地开发库中，尚无自动物理清理任务；后续清理需保留足够墓碑防止旧动作再次执行。
- 退出响应丢失时，在原 access 尚未过期、恢复窗口内可使用相同操作 ID 重试已撤销的退出；其他 API 不能使用此会话。旧 access 已被刷新替换时无法执行退出，客户端须用当前 access。

客户端收到业务 401 时只对 `UNAUTHENTICATED` 尝试共享刷新；`INVALID_CREDENTIALS` 是密码失败，`REFRESH_REPLAY` 终止会话。离线不等同于账号失效。需要最近身份确认的敏感动作尚未开放。

## 错误字典

| HTTP | code | 处理 |
| --- | --- | --- |
| 400 | `VALIDATION_FAILED` | 按 field 显示校验；ID、版本、空资料更新也属于校验 |
| 400 | `MALFORMED_PROTOBUF` | 非法二进制，修正请求编码 |
| 401 | `INVALID_CREDENTIALS` | 不区分账号不存在／密码不匹配 |
| 401 | `UNAUTHENTICATED` | 未提供、无效、撤销或到期的会话凭据 |
| 401 | `REFRESH_REPLAY` | 旧 refresh 换操作 ID 重放，会话已撤销 |
| 409 | `ACCOUNT_TAKEN` | 账号唯一性冲突 |
| 409 | `PROFILE_VERSION_CONFLICT` | 重新读取资料并处理冲突 |
| 409 | `OPERATION_CONFLICT` | 禁止复用 ID 提交新内容 |
| 409 | `AUTH_ATTEMPT_EXPIRED` | 重新完成密码认证；不能期待旧认证结果恢复 |
| 409 | `REFRESH_SUPERSEDED` | 忽略旧代结果，保留客户端较新认证包 |
| 409 | `OPERATION_RESULT_EXPIRED` | 先读取当前状态对账 |
| 406／415 | `NOT_ACCEPTABLE`／`UNSUPPORTED_MEDIA_TYPE` | 修正 Accept／Content-Type |
| 413 | `PAYLOAD_TOO_LARGE` | 请求超过 16 KiB |
| 429 | `RATE_LIMITED` | 最多等待 Retry-After 指示的 60 秒后重试 |
| 其他 HTTP 错误 | `HTTP_ERROR` | 包含不存在的路由；不解释为密码错误 |
| 500 | `INTERNAL_ERROR` | 内部错误，仅保留 request_id 供诊断 |

IP 每分钟最多 120 次；规范化账号的注册／登录合计每分钟最多 10 次；排队最多 64 个数据库操作。限流存于进程内，重启重置，来源使用连接地址而非客户端转发头，当前不支持反向代理、多实例或互联网暴露。
