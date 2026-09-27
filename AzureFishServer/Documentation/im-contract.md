# IM 网络契约 v1

> 本机虚构账号文本与媒体 IM 已实现，客户端尚未接入。唯一字段来源为 [azurefish.proto](../Protos/azurefish.proto)，产品范围见 [需求分析](im-requirements.md)。

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
- 文本接受 `content_type=text`、`content_schema_version=1`，非空且最多 16384 Swift Character／64 KiB UTF-8。允许换行，禁止其他控制字符。发送请求编码上限 256 KiB，其余控制请求仍是 16 KiB。媒体追加 `media_group`／`audio`／`file`，组合及字节接口见 [媒体契约](media-contract.md)。
- `message_uuid` 全环境唯一；`client_message_id` 在发送者内唯一。用新 operation_id 但相同消息身份和内容发送可对账返回当前消息；不同身份映射或内容返回 `MESSAGE_ID_CONFLICT`。跨设备不得重新冒用原 device_id 发新请求；客户端应先同步确认原发送结果。
- send／revoke 的幂等记录只保存消息身份，重试返回**当前**权威消息（含当前回执）；撤回后永远没有旧正文。其他成功操作在恢复窗口返回原结果，客户端按对应版本合并。
- 群资料版本仅随群管理变更增加；boundary_revision 仅随成员权限变化增加。message.server_revision 独立于 receipt.server_revision；会话 read_state 也有独立版本。解散或退群禁止新发送，但旧授权历史和撤回窗口仍有效。
- 每账号 IM 写每分钟 120 次，精确用户查询每分钟 20 次，并继续受控制路由共享的 IP 每分钟 120 次保护（媒体字节路由另为 600 次）。限流为进程内开发实现，不能用来保护公网服务。

## 历史、事件和固定快照

历史首次 `before_seq=upper_bound_seq=boundary_revision=0`，响应固定上界。后续沿用 upper_bound_seq、boundary_revision 和 next_before_seq；上界包含，before 不包含。页按消息序号降序，limit 默认 50、最大 100；扫描包含无权限缺口，因此空 messages 与 has_more=true 可以同时出现。覆盖闭区间只代表已扫描范围，必须结合成员可见区间解释，不能视作获取未授权正文的许可。首期不物理清理历史，earliest_available_seq 为首次加入边界。权限边界变更返回 `HISTORY_BOUNDARY_CHANGED`，重新开始历史分页。

events limit 默认 100、最大 200；响应至多 4 MiB，实际内容预算 3 MiB 预留封装。base_cursor 对应请求起点，next_cursor 对应已返回最后事件，has_more 表示还存在后续位置。空 cursor 从位置 0 开始，空 epoch 仅用于首次请求。游标签名绑定账号、资源、epoch 和位置；无效／跨账号游标拒绝，不跳到最新位置。相同事件的实体在读取时按当前权威状态物化，因此早期消息事件在撤回后也只有占位。

快照首次空 token／cursor，建立包含所有历史会话关系的固定数据和同步基线；后续携带相同 token 与返回的 cursor。快照 token 绑定账号与资源，10 分钟有效；新快照创建时清理过期快照，已清理 token 返回 `SNAPSHOT_NOT_FOUND`，尚未清理的过期 token 返回 `SNAPSHOT_EXPIRED`。limit 默认 50、最大 100，结束页才返回 baseline_cursor。`CURSOR_EXPIRED` 后客户端请求新的空 token 快照；错误本身不携带 token。保留本地草稿、outbox 和删除标记，完成后按基线补增量再补历史。快照只含 IM 会话／成员／阅读状态，不含联系人或全部正文。

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
