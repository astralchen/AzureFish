# 客户端与服务端同步契约

> **状态：设计阶段，尚未接入应用。所有接口均为拟定契约，当前工程没有对应真实服务端。** 本文中的请求／响应是数据示例，不是可调用 API。返回 [文档入口](README.md)。

## 1. 通用约定

认证身份和服务环境决定账号作用域，服务端不得信任客户端传入的 sender_id 代替认证。数据库以账号隔离；设备 ID 由登录设备注册流程分配。身份来源和认证消息以 [服务端网络契约](../../../AzureFishServer/Documentation/protobuf-contract.md) 为准。业务 ID 均为不透明字符串，时间为 Unix 毫秒；网络采用 Protobuf 二进制，64 位消息序号和版本号使用 int64。ProtoJSON 诊断文本中的 64 位值才使用十进制字符串；本文可读示例不代表网络使用 JSON。本地 payload JSON 由版本化 codec 显式转换，与网络格式独立。

服务端为普通消息透传原始 `message_uuid` 和 `client_message_id`。系统消息由服务端生成 `message_uuid`，客户端幂等 ID 可空。消息 UUID 在整个服务环境唯一；服务端消息 ID 和序号仅要求会话内唯一。

实体的 `server_revision` 在实体整个生命周期内单调递增，游标 epoch 变化不重置实体版本。只应用更高版本；同版本相同内容是幂等重放，同版本不同内容是协议错误，保留原数据、阻止该批次推进并请求修复。回执和未读摘要各有自己的版本，不与正文版本比较。

本文 IM API 能力用操作名描述，URL 路径和各操作的最终传输分工在后续 IM 阶段冻结。架构方向为 WSS 二进制实时事件＋HTTPS 可重放增量补偿，两者均采用 Protobuf；不能只靠连接在线保证可靠送达。已经定义的账号与用户 HTTP 路由归服务端协议文档，不在此另建一套。

| 操作 | 请求主要字段 | 成功响应 |
| --- | --- | --- |
| `resolveConversation` | 私聊目标用户或已有群目标 ID；创建请求携带幂等 operation_id | 权威 conversation_id、kind、target_id 和资料版本 |
| `sendMessage` | operation_id、message_uuid、client_message_id、conversation_id、device_id、content_type、content_schema_version、payload、资源对象键 | 完整权威消息信封：原身份、server_message_id、server_seq、server_created_at_ms、server_revision |
| `fetchEvents` | cursor、epoch、limit | base_cursor、events、next_cursor、epoch、has_more；含受影响会话的版本化阅读摘要 |
| `fetchHistory` | conversation_id、before_seq、upper_bound_seq、limit、boundary_revision | 消息、已验证覆盖区间、next_before_seq、has_more、earliest_available_seq、boundary_revision |
| `markRead` | operation_id、conversation_id、read_through_seq | 单调合并后的阅读水位、未读摘要及其版本 |
| `revokeMessage` | operation_id、conversation_id、message_uuid | 权威撤回事件或明确拒绝 |
| `fetchReceiptDetails` | conversation_id、message_uuid、snapshot_token、cursor、limit | audience_version、summary_revision、snapshot_token、成员明细、next_cursor、complete |
| `fetchSnapshot` | snapshot_token、cursor、limit | 固定快照实体页、next_cursor、complete；结束时提供对应增量基线 cursor |
| `authorizeResource` | resource_id、用途 | 有时效的上传／下载授权，不持久化到消息 payload |

未来 IM 首期拟定载荷上限：单条非媒体 Protobuf 消息编码后不超过 256 KiB，单个增量响应在任何解压之后不超过 4 MiB、事件不超过 200 条；是否启用响应压缩另行确定。转换后的本地 payload JSON 另做大小限制，不用 JSON 字节数推算网络字节数。客户端遇到超限批次要求服务端缩小分页，不跳过事件。媒体字节独立传输。这不是当前认证接口的体积上限。协议 v1 的未知事件类别不能悄悄丢弃并推进游标：暂停该批次并报告需要升级；未知消息内容类型则可按已知消息事件保存。

首期离线发送针对已经取得权威 conversation_id 的会话。首次发起新私聊需先完成 resolveConversation；离线时可以保存输入草稿，但不能伪造最终会话 ID 排队发送。未取得会话身份的临时输入由页面临时存储管理，不能误写入正式 draft 表。群创建、成员管理及联系人变更接口属于独立业务协议，本设计先定义其结果如何入库；不宣称这些管理流程已实现。

## 2. 身份合并与排序

| 身份 | 产生方 | 用途 | 是否可改变 |
| --- | --- | --- | --- |
| local_id | 本地数据库 | 行关联、当前设备列表身份 | 原行生命周期内不变，不上传 |
| message_uuid | 原发送端或系统服务 | 跨端通用业务身份、引用、撤回 | 不变 |
| client_message_id | 原发送端 | 发送幂等，以发送者＋客户端 ID 唯一 | 重试不变 |
| server_message_id | 服务端 | 会话内权威消息身份 | 不变 |
| server_seq | 服务端 | 会话内消息顺序 | 接受后不变，编辑和撤回不分配新位置 |
| sync cursor | 服务端事件流 | 消息以外事件也包含在内的同步进度 | 仅成功事务后前进 |

本机发送时可以让 message_uuid 与 client_message_id 使用同一 UUID，但存储职责仍分开。接收 ACK、推送和历史时按 UUID、发送者＋客户端 ID、会话＋服务端 ID 查找候选；多个候选必须一致指向同一行。遇到互相冲突的身份不可用 `REPLACE` 删除旧行，必须回滚并记录协议冲突。

其他设备以当前账号发送的消息，在本机直接保存为 `accepted`；他人消息为 `received`。方向通过发送者与账号比较，不依赖 send_state。其他设备消息不能自动创建本机重发任务。

已确认消息按 server_seq 升序展示。待确认消息保存创建时最新已知的 anchor_server_seq，临时排序为“该锚点后、下一个确认序号前”，同锚点按 local_id 排序。ACK 到来后以服务端顺序为准，保留相同 local_id，视图按可见消息身份恢复锚点。不会把本地时间或 local_id 写入 server_seq。

首次查询固定已确认历史上界，后续历史页沿 before_seq 向前读取；新增确认消息由观察流合并。分页不包含 pending 消息，也不受 pending 确认后的位置变化影响。Repository 对同一消息身份去重，初始 38 条、后续 20 条，返回值从旧到新。服务端序号可以有空洞，不能把不连续本身解释成丢消息。

## 3. 发送契约和失败重试

### 数据示例

| 阶段 | 示例 |
| --- | --- |
| 本机提交 | operation_id=`op-1`，message_uuid=`m-1`，client_message_id=`c-1`，conversation_id=`conv-7`，type=`text`，version=`1`，payload.text=`你好` |
| 首次请求超时 | 本机仍只有 local_id=`42`；任务进入 retry_wait，业务身份不变 |
| 重试请求 | 仍提交 `op-1 / m-1 / c-1` 和原内容 |
| 服务端接受 | 返回 `m-1 / c-1`，server_message_id=`s-900`，server_seq=`108`，server_revision=`1` |
| 同步回声 | 再次返回同一信封；更新 local_id=`42`，不能插入第二条消息 |

同一幂等 ID 携带不同内容时服务端返回 `idempotency_conflict`；用户修改失败消息内容再发送必须生成新的业务身份。资源上传以 resource_id 和摘要幂等，上传完成后服务端返回稳定对象键，签名 URL 只作为短期传输凭据。

消息状态：`queued → uploading（有待上传资源时）→ sending → accepted`。可恢复网络故障时消息维持当前阶段，任务进入 retry_wait；界面可显示等待网络。资源永久缺失、拒绝或重试预算耗尽进入 failed，用户重试回到 queued，身份不变。对他人消息的 received 为独立终态。

同一会话按本机提交顺序领取发送任务；上传未完成的队首发送会阻挡后续 queued 发送，已明确 failed 或 cancelled 的消息不再阻挡。多个设备之间的最终顺序由服务端接受序号决定。

accepted 不代表送达或已读。超时也不代表服务端没有接受。仅当发送命令从未开始网络尝试时，才能在本机保证取消发送；其余取消只能保证本机不再重试、隐藏消息，迟到接受仍需合并。需要对所有设备删除内容时申请撤回。

| 错误类别 | 策略 |
| --- | --- |
| 网络、5xx、临时上传失败 | 指数退避＋随机抖动；1 秒起，最多 5 分钟；连续 10 次网络尝试失败后转 failed，手动重试重置预算 |
| 限流 | 遵守 Retry-After，不早于退避时间；无网络时暂停，不空耗重试次数 |
| 认证失效 | 暂停账号工作流，刷新认证或等待重新登录，不误报消息已发送 |
| 被拉黑、无群权限、内容拒绝 | failed，保留可操作错误码，不能无穷重试 |
| 身份冲突、同版本冲突 | 停止相关命令／批次，保留诊断元数据并请求服务端修复 |

## 4. 增量同步、历史漫游与重建

### 一个增量批次

| 字段 | 示例 |
| --- | --- |
| 请求 | epoch=`e1`，cursor=`k10`，limit=`200` |
| 响应基线 | epoch=`e1`，base_cursor=`k10` |
| 事件 | message.upsert(`m-1`, revision=1)、message.revoke(`m-0`, revision=2)、conversation.read_state(revision=15) |
| 下一位置 | next_cursor=`k11`，has_more=`false` |

拉取结果入库前确认本地 epoch 和 cursor 仍等于请求基线；若已有其他工作者推进，则丢弃过期响应重新拉取。批次内事件依次处理，所有实体变更、投影及 `k11` 同事务提交。杀进程发生在提交前时仍从 k10 重拉；提交后从 k11 继续。会话、用户、成员占位必须在同事务内满足外键。

事件覆盖 message.upsert、message.revoke、conversation.upsert、group.membership、contact.upsert、receipt.cursor、receipt.summary、conversation.read_state。实体删除必须用明确删除状态／事件表达，不以某一分页没有出现实体来推断删除。

### 历史响应

例如请求会话 conv-7 的 before_seq=108、upper_bound_seq=108、limit=20；服务端返回序号 81～107 中当前账号有权看到的消息，声明覆盖闭区间 [81,107]，next_before_seq=81。即使其中只存在 18 条消息，该范围也可完整，不能靠条数判断 has_more。

history_range 记录服务端保证已查询完整的范围，或已不能恢复的范围。Repository 在同一 boundary_revision 下合并相邻同类区间、拆分重叠冲突；更高权限边界版本到来时使旧区间失效并重拉。成员区间使用 joined_seq 包含、left_seq 不包含；具体消息的接收范围仍以服务端 audience 为准。

本地已经保存的历史不会因服务端保留期结束自动删除。服务端无法提供的范围显示“更早记录不可恢复”，与网络错误分开。入群前无权访问的区间不能通过补拉绕过权限。

### 游标过期

1. 服务端返回 `cursor_expired` 和固定快照 token，本地 checkpoint 进入 resync，保留原库及本机数据。
2. 分页获取联系人、会话、成员和阅读摘要；每页实体和 snapshot_next_cursor 同事务提交，崩溃后继续该 token。
3. 快照必须显式提供失效关系／关闭实体信息，不能仅返回当前活跃实体而要求客户端猜测缺失项。snapshot_token 过期时从新快照重新开始，实体版本仍用于幂等合并。
4. 完成快照后切换到服务端提供的增量基线 cursor，再补拉需要的消息历史。
5. 保留草稿、未确认消息、outbox、本地清空边界和 tombstone；过期事件流不能导致本地内容复活。

## 5. 阅读、未读和回执

`local_read_through_seq` 是用户明确确认的阅读边界，`confirmed_read_through_seq` 是服务端合并该账号所有设备的水位。有效阅读边界取两者最大值。markRead 是 max 合并，不允许旧设备将水位倒退；发送端只能推进到服务端允许访问的会话边界。

只有页面位于前台、窗口活跃、最新消息实际显示时，才将可见最新确认序号推进为阅读边界；这表示此前所有消息一并视为已读，包括未下载的更早历史。进入历史浏览、后台接收、预览消息不自动推进。手动“全部已读”也必须明确使用一次已知服务端上界。

未读不使用 max_seq 减 read_seq。摘要记录 server_unread_count、summary_at_seq、summary_read_through_seq 和 server_revision。未读摘要随影响未读的事件更新，并与同一批次对齐：

- 本地阅读水位等于摘要水位，且无待校准本地隐藏时，以服务端摘要为基础。
- 本机删除未读消息时，对本地存在且在摘要未读范围内的 tombstone 按消息去重扣减；新摘要已经排除该消息时不能再次扣减。
- 本机水位更高且所需区间完整时，对区间内可计未读消息重新计算；如果水位已覆盖 summary_at_seq，该摘要覆盖范围未读为零。
- 存在缺口无法准确调整时保留非负暂估值，unread_is_exact=0，并发送 markRead／刷新摘要；不能伪称精确，也不能重复累加历史数据。
- 本机发出、撤回占位及不计未读的系统事件不计入未读；是否计未读由已知事件语义确定，未知普通消息保守计入。

清空聊天同时将有效阅读边界推进到清空时的已知最高确认序号，并排队 markRead。因此“清空正文”属于本地行为，但本次明确阅读操作会同步到其他设备。

私聊使用对方用户级送达／阅读水位，已读隐含送达。delivered_through_seq 表示服务端确认其设备已经覆盖这一范围，不能直接用对方收到的最大乱序序号代替。多设备的用户级回执由服务端合并，本机不猜测各设备状态。

群消息摘要由服务端提供 expected_count、delivered_count、read_count、audience_version 和 server_revision；满足 0 ≤ read ≤ delivered ≤ expected。发送者不计入接收人数；退群、重入和群成员变化不直接改变旧消息分母。服务端可以以更高版本纠正统计，不对计数盲目取 max。

明细首次请求获得 snapshot_token，后续页必须使用该 token。摘要被更新到新版本时保留人数但清空旧明细、旧 token 和完成状态。过期响应根据 token 和请求代次拒绝；同一快照内按 message＋user 去重。memberships 尚未下载不阻碍回执明细入库。未获取回执摘要时展示“待同步”，不能展示 0 人已读作为权威结果。

## 6. 删除、清空和撤回

| 动作 | 本机记录 | 同步影响 |
| --- | --- | --- |
| 删除单条 | tombstone.is_locally_deleted=1；清理本机可见正文、引用资源和搜索投影 | 不要求对方或自己的其他设备删除；未读仅本机扣减 |
| 清空聊天 | clear_through_seq=max(旧边界, 当前最高已知确认序号)；待确认消息逐条 tombstone 并停止重试 | 正文删除仅本机；同时上报阅读边界 |
| 隐藏会话 | is_hidden=1 | 新到且高于清空边界的可见消息重新显示会话 |
| 撤回申请 | 入队 revoke 命令，正文保持当前状态并显示操作进行中 | 只有服务端确认后转 revoked |
| 权威撤回 | 更新 revoked_revision、正文占位、摘要、未读和搜索；清理引用快照中的旧正文 | 所有设备应用同一事件 |

先收到撤回时写 tombstone，后续正文到达先查标记，禁止恢复正文。撤回为终态；更高版本的普通正文也不能解除撤回，除非未来协议显式新增恢复事件。已本地删除的消息可继续合并信封、server_seq 及回执，但保持隐藏。引用安全快照可在目标尚未下载时显示；知道目标撤回或本地删除后替换占位，不能从引用泄露已清除正文。

软删除不等于永久保存正文：本机删除后保留最小身份信封／tombstone，payload 替换为占位，资源引用释放。全量本地清空可分批擦除历史内容，但第一笔事务先提交清空边界与搜索过滤条件，查询立即不可见；后续维护不能短暂重新显示旧内容。首期 tombstone 不设自动过期，除非账号数据被明确清除。

## 7. 回执与同步的可执行性前提

当前没有账号服务和后端，本轮只定义契约。后续模拟服务端必须可注入 ACK 丢失、同一事件重放、乱序撤回、游标过期、成员重入、摘要纠正和分页 token 失效，验证客户端后才能接入真实服务。服务端若无法提供消息发送时接收范围或版本化回执快照，群人数不能以当前成员表近似替代，应将该能力标为待接入。
