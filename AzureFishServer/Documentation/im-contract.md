# IM 网络契约 v1

> 本机虚构账号文本与媒体 IM 已实现；客户端接入及运行边界见 [原版 UI 记录](../../Documentation/Design/Chat/original-ui-restoration.md)。唯一字段来源为 [azurefish.proto](../Protos/azurefish.proto)，产品范围见 [需求分析](im-requirements.md)。

## 传输与路由

HTTP 路由统一要求 Bearer 与 `Accept: application/protobuf`，POST 正文 `Content-Type: application/protobuf`。写动作带 operation_id；查询使用 POST 是为了传递二进制分页参数，查询不要求 operation_id。全部成功响应为 200。WS 在握手头发送 Bearer，不使用 URL token。当前仅回环 HTTP／WS，真实环境必须 HTTPS／WSS。

| POST 路径（前缀 `/v1/im`） | 请求 | 响应 |
| --- | --- | --- |
| `/users/lookup` | `IMLookupUserRequest` | `IMPublicUser` |
| `/conversations/resolve` | `IMResolveRequest` | `IMConversation` |
| `/groups/create` | `IMCreateGroupRequest` | `IMConversation` |
| `/groups/update` | `IMUpdateGroupRequest` | `IMConversation` |
| `/conversations/get` | `IMConversationRequest` | `IMConversation` |
| `/messages/send` | `IMSendRequest` | `IMMessage` |
| `/messages/revoke` | `IMRevokeRequest` | `IMMessage` |
| `/read` | `IMWatermarkRequest` | `IMReadState` |
| `/delivered` | `IMWatermarkRequest` | `IMReadState` |
| `/history` | `IMHistoryRequest` | `IMHistoryResponse` |
| `/events` | `IMEventsRequest` | `IMEventsResponse` |
| `/snapshot` | `IMSnapshotRequest` | `IMSnapshotResponse` |
| `/receipts` | `IMReceiptsRequest` | `IMReceiptsResponse` |

`GET /v1/im/live` 是 WebSocket upgrade：服务端发送二进制 `IMSyncHint`，连接建立后立即发送当前游标，每秒检查是否变化，约 25 秒重复提示作保活。提示不会推进已送达／已读；客户端用自己的已提交游标读取 events。客户端向此连接发送文本／二进制应用消息会被关闭，协议 ping／pong 由 WebSocket 处理。每 session 最多 4 条连接，进程最多 128 条；超额 upgrade 后以 1008 关闭。每秒重验原 Bearer，退出、刷新替换或 access 到期后关闭，客户端须使用新凭据重连。

## 校验与幂等

- UUID 都接受大小写并返回小写；operation_id 全局唯一、原始请求指纹包含未知字段，重试需原字节。普通写恢复窗口沿用账号接口 10 分钟，跨同一 session 的 token 刷新可重放。
- 文本接受 `content_type=text`、`content_schema_version=1`，非空且最多 16384 Swift Character／64 KiB UTF-8。允许制表、换行和回车，禁止其他 Unicode control；组合 emoji 的 ZWJ 等 format 字符保留。发送请求编码上限 256 KiB，其余控制请求仍是 16 KiB。媒体追加 `media_group`／`audio`／`file`，组合及字节接口见 [媒体契约](media-contract.md)。
- `message_uuid` 全环境唯一；`client_message_id` 在发送者内唯一。用新 operation_id 但相同消息身份和内容发送可对账返回当前消息；不同身份映射或内容返回 `MESSAGE_ID_CONFLICT`。跨设备不得重新冒用原 device_id 发新请求；客户端应先同步确认原发送结果。
- send／revoke 的幂等记录只保存消息身份，重试返回**当前**权威消息（含当前回执）；撤回后永远没有旧正文。其他成功操作在恢复窗口返回原结果，客户端按对应版本合并。
- 群资料版本仅随群管理变更增加；boundary_revision 仅随成员权限变化增加。message.server_revision 独立于 receipt.server_revision；会话 read_state 也有独立版本。解散或退群禁止新发送，但旧授权历史和撤回窗口仍有效。
- 每账号 IM 写每分钟 120 次，精确用户查询每分钟 20 次，并继续受控制路由共享的 IP 每分钟 120 次保护（媒体字节路由另为 600 次）。限流为进程内开发实现，不能用来保护公网服务。

## 富文本与链接兼容扩展

保持 schema_version=1，新增字段使用未占用编号：`IMSendRequest.text_runs=10`、`link_url=11`；`IMMessage.text_runs=16`、`link_url=17`。`IMTextRun.text=1`、`style=2`，style 的 1／2／4／8 分别表示粗体／斜体／下划线／删除线，可组合；其余位拒绝。

文本可不带格式；携带格式时最多 16384 个非空片段，按序拼接必须严格等于纯文本 `text`，共同遵循原正文长度限制。`content_type=link` 要求不带格式或附件，`text` 必须等于 `link_url`；仅接受具有非空 host 的 HTTP／HTTPS URL。媒体消息不能携带格式或链接字段。服务端不抓取网页、不生成预览和转写。

新增字段进入消息存储、请求指纹、发送返回、历史及事件。撤回同时清空纯文本、格式、URL 和附件；幂等重放返回已清理的当前消息。旧存储没有新增字段时为空，旧客户端可继续显示 `text` 纯文本投影；未知类型仍需安全降级。客户端扩展后对链接显示原始 URL，预览失败不丢失原文。

## 历史、事件和固定快照

历史首次 `before_seq=upper_bound_seq=boundary_revision=0`，响应固定上界。后续沿用 upper_bound_seq、boundary_revision 和 next_before_seq；上界包含，before 不包含。页按消息序号降序，limit 默认 50、最大 100；扫描包含无权限缺口，因此空 messages 与 has_more=true 可以同时出现。覆盖闭区间只代表已扫描范围，必须结合成员可见区间解释，不能视作获取未授权正文的许可。首期不物理清理历史，earliest_available_seq 为首次加入边界。权限边界变更返回 `HISTORY_BOUNDARY_CHANGED`，重新开始历史分页。

events limit 默认 100、最大 200；响应至多 4 MiB，实际内容预算 3 MiB 预留封装。base_cursor 对应请求起点，next_cursor 对应已返回最后事件，has_more 表示还存在后续位置。空 cursor 从位置 0 开始，空 epoch 仅用于首次请求。游标签名绑定账号、资源、epoch 和位置；无效／跨账号游标拒绝，不跳到最新位置。相同事件的实体在读取时按当前权威状态物化，因此早期消息事件在撤回后也只有占位。

快照首次空 token／cursor，建立包含所有历史会话关系的固定数据和同步基线；后续携带相同 token 与返回的 cursor。快照 token 绑定账号与资源，10 分钟有效；新快照创建时清理过期快照，已清理 token 返回 `SNAPSHOT_NOT_FOUND`，尚未清理的过期 token 返回 `SNAPSHOT_EXPIRED`。limit 默认 50、最大 100，结束页才返回 baseline_cursor。`CURSOR_EXPIRED` 后客户端请求新的空 token 快照；错误本身不携带 token。保留本地草稿、outbox 和删除标记，完成后按基线补增量再补历史。快照包含 IM 会话／成员／阅读状态及联系人当前投影，不含全部消息正文。

回执分母固定为接受消息时的活跃成员减发送者。满足 `read_count ≤ delivered_count ≤ expected_count`；退群和重入不改变旧分母。仅消息发送者可查明细，首次空 token，分页时固定 token／cursor，不把旧明细与新摘要混合。收到 read／receipt 会话事件后按需刷新可见消息的回执。

## 错误与恢复

通用 `ApiError`、request_id、no-store、401 刷新规则沿用 [账号契约](protobuf-contract.md)。新增错误：

| HTTP | code | 客户端动作 |
| --- | --- | --- |
| 400 | `UNSUPPORTED_CONTENT`／`NOT_A_GROUP` | 修正内容类型或目标 |
| 400 | `INVALID_CURSOR` | 停止推进；检查账号、分页资源与游标完整性 |
| 401 | `UNAUTHENTICATED` | 沿用共享刷新策略 |
| 403 | `DEVICE_MISMATCH` | 校验凭据绑定设备 |
| 403 | `OWNER_REQUIRED`／`REVOKE_FORBIDDEN`／`RECEIPT_FORBIDDEN` | 不自动重试权限失败 |
| 403 | `CONVERSATION_CLOSED` | 保留输入；更新会话关闭状态 |
| 404 | `USER_NOT_FOUND`／`CONVERSATION_NOT_FOUND`／`MESSAGE_NOT_FOUND`／`MEMBER_NOT_FOUND` | 目标不存在或不可见；不区分未授权目标 |
| 404 | `SNAPSHOT_NOT_FOUND` | 不复用其他账号／资源 token；必要时重建快照 |
| 409 | `CONVERSATION_VERSION_CONFLICT` | 读取最新资料，保留编辑，不静默覆盖 |
| 409 | `MESSAGE_ID_CONFLICT` | 停止该消息重试并对账；不能换 ID 盲目重发 |
| 409 | `ALREADY_MEMBER`／`OWNER_TRANSFER_REQUIRED` | 刷新成员或先转让群主 |
| 409 | `REVOKE_WINDOW_EXPIRED` | 撤回超时，保留已接受消息 |
| 409 | `HISTORY_BOUNDARY_CHANGED` | 使用当前成员边界重新分页 |
| 409 | `CURSOR_EXPIRED`／`SNAPSHOT_EXPIRED` | 获取新固定快照并保留本地非同步数据 |
| 409 | `CONVERSATION_LIMIT`／`MEMBERSHIP_LIMIT`／`MESSAGE_LIMIT`／`SNAPSHOT_TOO_LARGE` | 达到开发上限；不重试制造更多记录 |
| 429 | `SNAPSHOT_LIMIT`／`RATE_LIMITED` | 等待、复用已有快照，避免重复创建 |

断网、500、响应丢失：写操作保留原字节和 operation_id；恢复窗口到期返回 `OPERATION_RESULT_EXPIRED` 时先通过历史／事件／当前资料对账。客户端不能把网络错误解释为消息已拒绝，也不能因新窗口或语言切换重新发送。

### 好友接受系统提示（2026-09-28）

`accept` 与私聊创建／复用、`system` 消息、双方事件、幂等结果同事务提交；失败整体回滚。新增系统提示双方各计一条未读，接受方不自动已读。每次关系接受版本最多生成一条，删除再添加使用原会话和新版本；旧好友不补历史。

`IMMessage.system_event = 18` 保存 `friendship_accepted`、关系 ID／版本、申请人及接受人。系统消息由服务端生成身份，无用户发送者、设备、client_message_id、文本正文或回执；客户端发送接口不支持此类型，撤回返回 `REVOKE_FORBIDDEN`，回执明细返回 `RECEIPT_FORBIDDEN`。

`IMConversation.latest_message = 11` 返回权限范围内最后消息，适用于快照及增量摘要；不表示历史覆盖。客户端按结构化事件本地化，未知类型保持消息身份并显示占位。旧客户端仍可同步消息信封。没有新增 HTTP 路由或数据库表。

## 通讯录语义 v2（未发版统一升级）

`/v1/im/contacts/get` 返回当前账号投影；`/v1/im/contacts/mutate` 必须声明 `semantics_version=2`。动作包含 request、accept、reject、cancel、delete、restore、remark、block、unblock，写操作继续使用 operation_id 和 expected_revision。请求／响应新增字段以权威 proto 为准，不复用已有编号。

`is_contact` 为自己的保留标记，`remark` 和 `is_blocked` 只属于本人。`request_id`、`request_state`、`request_message`、`request_updated_at_ms` 为最近申请；accept／reject／cancel 必须同时提供当前投影版本和相同 request_id；缺失或不匹配均拒绝。`available_actions` 包含有效动作及 send。`state` 是当前账号的派生显示状态，不再作为双方发送权限来源。

删除仅移除本人条目；双方保留且均未拉黑才允许私聊、私聊媒体创建和互相邀请入群。一方保留时另一方可 restore；双方移除则 request。待处理申请必须先处理，不绕过申请直接 restore。block 结束当前 pending 申请，不删除关系或历史；unblock 不恢复申请。既有群内发消息不受联系人删除或拉黑影响。

备注最多 64 Character，申请留言最多 200 Character，可为空，其他文本校验沿用 Validation.text。备注修改只提升本人投影版本并产生本人同步事件；关系与申请变化提升双方投影并产生双方事件。接受仍与系统消息同事务；直接 restore 不新增系统消息。旧重试返回当前投影，禁止重放出已被删除的旧状态。

新错误：CONTACT_CLIENT_UPDATE_REQUIRED（409，升级客户端／服务端）、CONTACT_UNAVAILABLE（403，中性不可用提示，不暴露对方私有设置）。原 CONTACT_VERSION_CONFLICT、CONTACT_ACTION_UNAVAILABLE 继续触发读取权威关系并保留输入。旧加密 payload 通过 UpgradeContactSides 迁移，保留 ID 和历史，新增单调版本及同步事件；不可无损降级。

### 公共资料同步

昵称保存与联系人、会话资料投影推进在同一事务内完成。联系人只推进看见此人新昵称的另一方投影，不改写备注或申请时间；群资料向仍可读取实时投影的成员发送更新，已冻结的离群快照保持原样。公共资料缓存独立比较 `profile_version`，旧关系或会话响应不得覆盖较新资料。

`IMSyncHint.own_profile_version` 唤醒同账号在线设备，`IMEventsResponse.own_profile_version` 提供 HTTP 对账值；设备发现版本上升后读取 `/me`，包括没有联系人和会话的账号。WebSocket 只提供提示，不提交客户端游标。`own_profile_version` 仅表示本账号版本，其他人的公开昵称及 `profile_version` 仍通过原有权限投影返回。
