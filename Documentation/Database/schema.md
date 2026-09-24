# 表结构与字段字典

> **状态：设计阶段，尚未接入应用。** 本文只描述目标结构，不提供可执行建表或迁移脚本。字段、枚举与约束需在后续 GRDB 实施中逐项落实。返回 [文档入口](README.md)。

## 通用规则

本库通过 SQLCipher 整库加密，字段逻辑类型不因此改为逐字段 BLOB；密钥不写入业务表。SQLCipher 版本与本地媒体信封版本不同，详见 [安全设计](../Security/README.md)。

- 单库对应一个环境和账号，账号身份只在 `account_store_meta` 记录；业务表不重复混入其他账号数据。真实用户 ID 与当前账号身份不是同一概念。
- 时间采用 Unix 毫秒 `INTEGER`；业务 ID 用 `TEXT`；布尔为 0/1。所有 PK 非空；INTEGER PRIMARY KEY 的自动分配不是业务身份。
- 字段权威标记：**S** 服务端权威；**L** 本机权威状态；**P** 可重建投影；**I** 稳定身份或双方共同约定。本机尚未发送的内容是待提交值，接受后以服务端规范化结果为准。
- `—` 表示没有默认值，插入时必须提供必填值；NULL 与空字符串不同。零版本表示占位或尚未获得服务端版本，收到权威实体后按版本合并。
- 普通外键删除行为默认 RESTRICT/NO ACTION；仅明确列出的从属内容使用 CASCADE。核心消息采用隐藏／占位，不能用级联物理删除代替撤回或清空语义。
- `JSON` 在 SQLite 中用 TEXT 保存；内容由 codec 检查。相对路径、payload 引用、群会话类型、跨字段业务状态和区间不重叠等由 Repository 补充校验，不能误称数据库已经强制保证。
- 已知消息类型的 payload 每消息一份；富文本是有序语义片段，媒体列表以 `message_attachment.ordinal` 为结构化顺序源。未知类型保留原始版本化对象。
- 首期不使用 STRICT 表、较新版本 JSONB 或 FTS contentless-delete 等依赖新 SQLite 的功能；SQLCipher 构建能力及最低 iOS 15 支持需分别验证。

## 状态与枚举流转

| 状态领域 | 合法流转及合并规则 |
| --- | --- |
| 联系人 relationship | none → friend → deleted；重新添加可回 friend，必须是更高服务端版本；is_blocked 独立 |
| 会话 availability | active → left/closed；重入可由更高版本回 active，closed 是否允许恢复由服务端明确事件决定 |
| 群成员 role／区间 | role 由服务端版本决定；退出填写 left_seq，重入新建 membership_id，不复用已退出关系 |
| message.send_state | queued → uploading（可跳过）→ sending → accepted；永久失败／预算耗尽 → failed；显式重试 failed → queued；未确认可 cancelled；他人消息 received；迟到权威 ACK 可将 cancelled 合并为 accepted，但 tombstone 继续隐藏 |
| message.revoke_state | none → revoked，首期不可逆；pending 撤回由 outbox 表示，不伪造权威撤回 |
| media_resource.local_state | absent → staged → ready；ready → missing／absent（仅缓存淘汰）；恢复后 ready；无引用回收 → deleting → 删除记录 |
| task.state | queued/retry_wait → running → succeeded；临时失败 → retry_wait；不可恢复 → failed；允许取消 → cancelled；显式恢复需重新领取 token |
| sync.phase | bootstrap → incremental；游标过期 → resync；固定快照完成 → incremental |
| 回执 detail.state | 同快照 pending/delivered/read 是状态快照；新的摘要版本使旧明细失效，不在不同快照间盲目递增 |
| 布尔、计数、类型 | 枚举允许值与 CHECK 见各表；content_type 为开放字符串，兼容未来类型 |

状态转换不全由 CHECK 表达，必须由 Repository 和任务的条件更新保证；只验证某个值合法不能证明某次流转合法。

## 首期表总览

| 表 | 用途 | 数据粒度 |
| --- | --- | --- |
| `account_store_meta` | 账号库元数据 | 每库固定一行，打开时核对身份。search_generation 为该库搜索失效序列。 |
| `user_profile` | 用户资料 | 每个用户一行，包括当前账号、联系人和陌生群成员；允许占位。 |
| `contact` | 联系人关系 | 当前账号对某用户的一条关系；备注和拉黑是关系属性，不污染用户公共资料。 |
| `conversation` | 会话定义 | 每个会话一行；首期每个 kind＋target_id 只有一个会话。群解散后重建必须使用新 group_id。 |
| `chat_group` | 群资料 | 每群一行，一对一关联群会话。 |
| `group_membership` | 群成员历史 | 每次入群一行，用户重入获得新 membership_id；同群同用户最多一条未退出关系。 |
| `message` | 消息信封 | 每个业务消息一行；local_id 永不因重试或确认重建。UUID 和客户端 ID 由原发送端透传。 |
| `message_payload` | 消息内容 | 与消息一对一；JSON 类型及版本在 message 上定义。未知类型保存原始 JSON，清除后用占位 JSON。 |
| `conversation_local_state` | 会话本机投影 | 每会话一行；置顶、免打扰、隐藏、清空和草稿修订序列是本机权威状态，其余为可重建展示投影。 |
| `message_relation` | 引用与回复 | 每消息每关系类别一行；引用目标为弱关联，正文尚未下载时仍可存在。 |
| `message_mention` | @实体 | 每消息每正文实体一行，UTF-16 范围基于纯文本拼接结果。 |
| `media_asset` | 逻辑媒体 | 一个逻辑附件一行，可有多个物理资源并被多条消息／草稿引用。 |
| `media_resource` | 物理资源 | 每个 asset 的每种 role 最多一行；Live Photo 的 original 与 paired_video 是两个资源。 |
| `message_attachment` | 消息附件引用 | 每消息每 ordinal 一个逻辑附件，同一 asset 可被多个消息引用。 |
| `draft` | 会话草稿 | 每会话每设备一份；不在首期跨设备同步。空白正文仍可为有效草稿。 |
| `draft_attachment` | 草稿附件引用 | 每会话草稿的唯一槽位一行，正文载荷按 slot／asset_id 关联。 |
| `conversation_read_state` | 自己的阅读与未读摘要 | 每会话一行；本机意图与服务端确认分开保存，有效水位取最大值。 |
| `member_receipt_cursor` | 用户回执水位 | 每会话每用户一行，服务端合并多个设备；不能替代群消息的接收范围。 |
| `message_receipt_summary` | 群消息回执摘要 | 一条发出消息一份权威人数与当前明细缓存状态；无行表示尚未知。 |
| `message_receipt_detail` | 回执明细缓存 | 按需缓存一个消息快照下的用户状态；同一消息用户最多一行。 |
| `message_tombstone` | 删除与撤回标记 | 每会话每消息 UUID 一行，可同时有本地删除和服务端撤回；目标消息可以不存在。 |
| `sync_checkpoint` | 同步进度 | 每个独立同步流一行，v1 使用 account_events；历史分页不写这里。 |
| `history_range` | 历史覆盖区间 | 会话中已确认查询完整或不可恢复的闭区间；不等于每个整数 seq 都有消息。 |
| `outbox_operation` | 持久业务命令 | 每个幂等 send／read／revoke 命令一行，JSON 参数包含协议版本，不包含短期授权。 |
| `transfer_job` | 资源传输任务 | 每资源每方向至多一行，重新建立传输递增 generation。 |
| `maintenance_job` | 维护任务 | 每维护目的 dedupe_key 一行，payload 含版本和恢复进度。 |
| `search_document` | 搜索投影 | 每种实体身份一行；消息投影强关联 local_id，联系人和会话由 Repository 核对类型。 |
| `search_dirty` | 搜索失效队列 | 每实体一行最新失效；generation 从库级单调计数分配，避免行删除后的 ABA。 |
| `legacy_import` | 旧草稿导入记录 | 每个旧清单身份一行，摘要用于识别已成功导入的源版本。 |
| `search_fts` | FTS5 虚拟索引 | 每个 search_document 对应一个 rowid，底层 shadow 表由 SQLite 管理 |

## 1. account_store_meta：账号库元数据

每库固定一行，打开时核对身份。search_generation 为该库搜索失效序列。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `singleton` | INTEGER | 否 | — | L | 单账号库唯一元数据行 |
| `account_id` | TEXT | 否 | — | I | 当前账号 ID，打开数据库时校验 |
| `environment_id` | TEXT | 否 | — | I | 服务环境标识，生产与测试必须隔离 |
| `store_uuid` | TEXT | 否 | — | L | 本机数据库实例身份，恢复时用于识别旧任务 |
| `search_generation` | INTEGER | 否 | `0` | L | 搜索失效全局递增代次，移除 dirty 行后也不回退 |
| `created_at_ms` | INTEGER | 否 | — | L | 创建时间 |

### 约束与索引

- 主键：`(singleton)`。
- 唯一约束：`(store_uuid)`。
- 检查约束：`(singleton = 1)`。
- 检查约束：`(search_generation >= 0)`。

### 典型访问与事务

- 查询：按 singleton=1 读取并核对账号、环境和 store_uuid。
- 写入边界：仅首次建库写身份；分配 search_generation 必须与 search_dirty 更新同事务。

## 2. user_profile：用户资料

每个用户一行，包括当前账号、联系人和陌生群成员；允许占位。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `user_id` | TEXT | 否 | — | I | 用户身份，不等同于当前登录账号 |
| `nickname` | TEXT | 否 | `''` | S | 昵称，占位用户允许空值 |
| `avatar_asset_key` | TEXT | 是 | — | S | 可重新授权获取的头像资源键，不存临时签名 URL |
| `is_placeholder` | INTEGER | 否 | `1` | L | 是否等待补全用户资料 |
| `server_revision` | INTEGER | 否 | `0` | S | 资料版本 |
| `updated_at_ms` | INTEGER | 否 | — | S | 最近资料更新时间 |

### 约束与索引

- 主键：`(user_id)`。
- 检查约束：`(is_placeholder IN (0,1))`。
- 检查约束：`(server_revision >= 0)`。

### 典型访问与事务

- 查询：按 user_id 点查；联系人搜索走搜索投影，不在此表做全表模糊扫描。
- 写入边界：创建引用用户的消息／成员前先插入占位；资料按 server_revision 合并，并使相关搜索失效。

## 3. contact：联系人关系

当前账号对某用户的一条关系；备注和拉黑是关系属性，不污染用户公共资料。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `user_id` | TEXT | 否 | — | I | 当前账号与此用户的唯一联系人关系 |
| `remark` | TEXT | 否 | `''` | S | 当前账号设置的备注，可跨设备同步 |
| `relationship` | TEXT | 否 | `'none'` | S | 联系人关系 |
| `is_blocked` | INTEGER | 否 | `0` | S | 当前账号是否拉黑对方 |
| `server_revision` | INTEGER | 否 | `0` | S | 关系版本 |
| `updated_at_ms` | INTEGER | 否 | — | S | 关系更新时间 |

### 约束与索引

- 主键：`(user_id)`。
- 外键：`(user_id)` → `user_profile(user_id)`；删除行为 `NO ACTION`。
- 检查约束：`(relationship IN ('none','friend','deleted'))`。
- 检查约束：`(is_blocked IN (0,1))`。
- 检查约束：`(server_revision >= 0)`。

### 典型访问与事务

- 查询：按 user_id 查询关系和备注；好友列表按 relationship 筛选后分页。
- 写入边界：联系人更新和用户占位、搜索失效及同步游标同事务；收到 deleted 保留关系版本。

## 4. conversation：会话定义

每个会话一行；首期每个 kind＋target_id 只有一个会话。群解散后重建必须使用新 group_id。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `conversation_id` | TEXT | 否 | — | I | 服务端分配的会话 ID；演示账号使用独立命名空间 |
| `kind` | TEXT | 否 | — | S | 会话类型 |
| `target_id` | TEXT | 否 | — | S | 私聊对方用户 ID、群 ID 或系统频道 ID |
| `title` | TEXT | 否 | `''` | S | 会话显示标题 |
| `availability` | TEXT | 否 | `'active'` | S | 可发送、已退群或关闭 |
| `server_revision` | INTEGER | 否 | `0` | S | 会话资料版本 |
| `created_at_ms` | INTEGER | 否 | — | S | 会话创建时间 |

### 约束与索引

- 主键：`(conversation_id)`。
- 唯一约束：`(kind, target_id)`。
- 检查约束：`(kind IN ('direct','group','system'))`。
- 检查约束：`(availability IN ('active','left','closed'))`。
- 检查约束：`(server_revision >= 0)`。

### 典型访问与事务

- 查询：按 conversation_id 点查，或以 kind＋target_id 定位已存在私聊。
- 写入边界：会话占位与依赖消息同事务；创建时初始化 local_state 和 read_state；服务端资料按版本更新。

## 5. chat_group：群资料

每群一行，一对一关联群会话。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `group_id` | TEXT | 否 | — | I | 群 ID，Repository 校验与 conversation.target_id 一致 |
| `conversation_id` | TEXT | 否 | — | I | 群对应会话 |
| `owner_user_id` | TEXT | 是 | — | S | 群主，资料不完整时允许空 |
| `member_count` | INTEGER | 否 | `0` | S | 服务端当前有效成员数 |
| `membership_revision` | INTEGER | 否 | `0` | S | 成员列表版本 |
| `server_revision` | INTEGER | 否 | `0` | S | 群资料版本 |

### 约束与索引

- 主键：`(group_id)`。
- 唯一约束：`(conversation_id)`。
- 外键：`(owner_user_id)` → `user_profile(user_id)`；删除行为 `NO ACTION`。
- 外键：`(conversation_id)` → `conversation(conversation_id)`；删除行为 `NO ACTION`。
- 检查约束：`(member_count >= 0)`。
- 检查约束：`(membership_revision >= 0)`。
- 检查约束：`(server_revision >= 0)`。

### 典型访问与事务

- 查询：按 group_id 或 conversation_id 定位群资料。
- 写入边界：群资料、会话与相关占位用户同事务；Repository 校验会话 kind=group 且 target_id=group_id。

## 6. group_membership：群成员历史

每次入群一行，用户重入获得新 membership_id；同群同用户最多一条未退出关系。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `membership_id` | TEXT | 否 | — | I | 每次入群的独立成员关系身份 |
| `conversation_id` | TEXT | 否 | — | I | 所属群会话 |
| `user_id` | TEXT | 否 | — | I | 成员用户 |
| `display_name` | TEXT | 否 | `''` | S | 群内昵称 |
| `role` | TEXT | 否 | `'member'` | S | 群角色 |
| `joined_seq` | INTEGER | 否 | — | S | 可访问成员区间下界，具体边界按同步契约 |
| `left_seq` | INTEGER | 是 | — | S | 退出后的区间上界，NULL 表示仍有效 |
| `server_revision` | INTEGER | 否 | — | S | 成员关系版本 |

### 约束与索引

- 主键：`(membership_id)`。
- 索引 `idx_membership_user`：`group_membership(user_id, conversation_id)`。用途见本表典型访问。
- 索引 `idx_membership_active`：唯一；`group_membership(conversation_id, user_id) WHERE left_seq IS NULL`。用途见本表典型访问。
- 唯一约束：`(conversation_id, membership_id)`。
- 外键：`(user_id)` → `user_profile(user_id)`；删除行为 `NO ACTION`。
- 外键：`(conversation_id)` → `chat_group(conversation_id)`；删除行为 `NO ACTION`。
- 检查约束：`(role IN ('member','admin','owner'))`。
- 检查约束：`(joined_seq >= 0)`。
- 检查约束：`(left_seq >= joined_seq)`。
- 检查约束：`(server_revision >= 0)`。

### 典型访问与事务

- 查询：按 conversation_id 查有效成员，历史按 membership_id 点查；用户查群使用 idx_membership_user。
- 写入边界：成员替换先关闭旧 active 关系再插入新关系，和群 membership_revision、checkpoint 同事务；joined_seq 包含、left_seq 不包含。

## 7. message：消息信封

每个业务消息一行；local_id 永不因重试或确认重建。UUID 和客户端 ID 由原发送端透传。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `local_id` | INTEGER | 否 | 自动分配 | L | 本库稳定递增行 ID，供列表身份与关联使用 |
| `message_uuid` | TEXT | 否 | — | I | 原始发送端生成、服务端透传的全局消息 UUID |
| `conversation_id` | TEXT | 否 | — | I | 所属会话 |
| `sender_id` | TEXT | 否 | — | S | 发送者，资料缺失时先建占位用户 |
| `sender_device_id` | TEXT | 是 | — | S | 来源设备 ID，系统消息可空 |
| `client_message_id` | TEXT | 是 | — | I | 原始发送端幂等 ID，普通客户端消息必须提供 |
| `server_message_id` | TEXT | 是 | — | S | 服务端消息 ID，与 server_seq 同时出现 |
| `server_seq` | INTEGER | 是 | — | S | 会话内不可变且唯一的消息序号 |
| `anchor_server_seq` | INTEGER | 否 | `0` | L | 未确认消息创建时最近的服务端序号 |
| `content_type` | TEXT | 否 | — | I | 可扩展类型，如 text、media_group、file、link、system |
| `content_schema_version` | INTEGER | 否 | — | I | 当前类型载荷版本 |
| `server_revision` | INTEGER | 否 | `0` | S | 正文及撤回变更版本 |
| `send_state` | TEXT | 否 | — | L | 接收消息或本机发送流程状态 |
| `revoke_state` | TEXT | 否 | `'none'` | S | 服务端权威撤回状态 |
| `local_created_at_ms` | INTEGER | 否 | — | L | 本地首次创建时间 |
| `server_created_at_ms` | INTEGER | 是 | — | S | 服务端接受时间 |
| `last_error_code` | TEXT | 是 | — | L | 最近发送失败代码，成功后清空 |
| `search_text` | TEXT | 否 | `''` | P | 可检索纯文本，撤回时清空 |

### 约束与索引

- 主键：`(local_id)`。
- 索引 `idx_message_pending`：`message(conversation_id, anchor_server_seq, local_id) WHERE server_seq IS NULL`。用途见本表典型访问。
- 索引 `idx_message_sequence`：唯一；`message(conversation_id, server_seq DESC) WHERE server_seq IS NOT NULL`。用途见本表典型访问。
- 索引 `idx_message_server`：唯一；`message(conversation_id, server_message_id) WHERE server_message_id IS NOT NULL`。用途见本表典型访问。
- 索引 `idx_message_client`：唯一；`message(sender_id, client_message_id) WHERE client_message_id IS NOT NULL`。用途见本表典型访问。
- 唯一约束：`(local_id, conversation_id)`。
- 唯一约束：`(message_uuid)`。
- 外键：`(sender_id)` → `user_profile(user_id)`；删除行为 `NO ACTION`。
- 外键：`(conversation_id)` → `conversation(conversation_id)`；删除行为 `NO ACTION`。
- 检查约束：`(server_seq > 0)`。
- 检查约束：`(anchor_server_seq >= 0)`。
- 检查约束：`(content_schema_version > 0)`。
- 检查约束：`(server_revision >= 0)`。
- 检查约束：`(send_state IN ('received','queued','uploading','sending','accepted','failed','cancelled'))`。
- 检查约束：`(revoke_state IN ('none','revoked'))`。
- 检查约束：`((server_message_id IS NULL AND server_seq IS NULL) OR (server_message_id IS NOT NULL AND server_seq IS NOT NULL))`。
- 检查约束：`(send_state NOT IN ('accepted','received') OR server_seq IS NOT NULL)`。
- 检查约束：`(send_state = 'received' OR client_message_id IS NOT NULL)`。

### 典型访问与事务

- 查询：历史使用 conversation_id＋server_seq<边界降序限量查询，返回时逆序；pending 走独立部分索引；同样过滤 tombstone 和 clear_through_seq。
- 写入边界：消息、payload、关系、资源引用、摘要、outbox 或同步 cursor 同事务；应用层验证正文存在、当前账号方向和状态，不能用 REPLACE 合并。

## 8. message_payload：消息内容

与消息一对一；JSON 类型及版本在 message 上定义。未知类型保存原始 JSON，清除后用占位 JSON。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `message_local_id` | INTEGER | 否 | — | L | 与消息一对一 |
| `payload_json` | TEXT | 否 | — | S | 类型化或未知原始载荷；本机发送前为待提交值，版本见 message |

### 约束与索引

- 主键：`(message_local_id)`。
- 外键：`(message_local_id)` → `message(local_id)`；删除行为 `CASCADE`。

### 典型访问与事务

- 查询：先批量取得一页 message.local_id，再批量获取 payload，避免每条消息单独查询。
- 写入边界：与信封同事务创建或更新；SQLite 外键仅保证子到父，Repository 必须保证提交时每个可见消息有 payload。

## 9. conversation_local_state：会话本机投影

每会话一行；置顶、免打扰、隐藏、清空和草稿修订序列是本机权威状态，其余为可重建展示投影。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `conversation_id` | TEXT | 否 | — | I | 会话本机状态 |
| `last_message_local_id` | INTEGER | 是 | — | P | 最新可见消息，可能为本机待发送消息 |
| `last_message_digest` | TEXT | 否 | `''` | P | 原始摘要或类型标识，由展示层本地化 |
| `activity_at_ms` | INTEGER | 否 | `0` | P | 最近可见活动时间，历史补拉不无条件顶起会话 |
| `unread_count` | INTEGER | 否 | `0` | P | 当前显示未读，依据阅读水位及权威摘要计算 |
| `unread_is_exact` | INTEGER | 否 | `1` | P | 未读是否已确认，0 表示暂估待校准 |
| `is_pinned` | INTEGER | 否 | `0` | L | 本设备置顶 |
| `is_muted` | INTEGER | 否 | `0` | L | 本设备前台提醒偏好，不声明已经配置服务端推送免打扰 |
| `is_hidden` | INTEGER | 否 | `0` | L | 本设备隐藏，后续新消息可重新显示 |
| `clear_through_seq` | INTEGER | 否 | `0` | L | 本机清空边界，漫游不得复活该范围 |
| `draft_revision` | INTEGER | 否 | `0` | L | 草稿持久修订序列；保存与删除均递增，删除后不归零 |

### 约束与索引

- 主键：`(conversation_id)`。
- 索引 `idx_conversation_list`：`conversation_local_state(is_pinned DESC, activity_at_ms DESC, conversation_id) WHERE is_hidden = 0`。用途见本表典型访问。
- 外键：`(last_message_local_id, conversation_id)` → `message(local_id, conversation_id)`；删除行为 `NO ACTION`。
- 外键：`(conversation_id)` → `conversation(conversation_id)`；删除行为 `NO ACTION`。
- 检查约束：`(unread_count >= 0)`。
- 检查约束：`(unread_is_exact IN (0,1))`。
- 检查约束：`(is_pinned IN (0,1))`。
- 检查约束：`(is_muted IN (0,1))`。
- 检查约束：`(is_hidden IN (0,1))`。
- 检查约束：`(clear_through_seq >= 0)`。
- 检查约束：`(draft_revision >= 0)`。

### 典型访问与事务

- 查询：is_hidden=0 按 is_pinned DESC、activity_at_ms DESC、conversation_id 做 keyset 分页。
- 写入边界：消息变更、删除、草稿发送及摘要更新同事务；last_message 必须属于同一会话，隐藏旧历史不能顶起会话。

## 10. message_relation：引用与回复

每消息每关系类别一行；引用目标为弱关联，正文尚未下载时仍可存在。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `message_local_id` | INTEGER | 否 | — | L | 引用方消息 |
| `conversation_id` | TEXT | 否 | — | I | 引用方会话 |
| `relation_kind` | TEXT | 否 | — | I | 回复或引用 |
| `target_message_uuid` | TEXT | 否 | — | I | 被引用消息 UUID，无外键以允许未下载历史 |
| `snapshot_json` | TEXT | 否 | — | S | 引用安全快照，不包含绝对路径；撤回目标时替换为占位 |

### 约束与索引

- 主键：`(message_local_id, relation_kind)`。
- 索引 `idx_relation_target`：`message_relation(conversation_id, target_message_uuid)`。用途见本表典型访问。
- 外键：`(message_local_id, conversation_id)` → `message(local_id, conversation_id)`；删除行为 `CASCADE`。
- 检查约束：`(relation_kind IN ('reply','quote'))`。

### 典型访问与事务

- 查询：按源 local_id 查关系；按 conversation_id＋target_message_uuid 找需替换占位的引用快照。
- 写入边界：写消息时一起写关系；撤回或本地删除目标时同事务清理已知引用的安全快照；不自动撤销普通文字复制。

## 11. message_mention：@实体

每消息每正文实体一行，UTF-16 范围基于纯文本拼接结果。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `message_local_id` | INTEGER | 否 | — | L | 所属消息 |
| `ordinal` | INTEGER | 否 | — | I | 文本实体顺序 |
| `mention_kind` | TEXT | 否 | — | I | 指定成员或所有人 |
| `user_id` | TEXT | 是 | — | I | 被提及用户，all 时为空 |
| `range_start_utf16` | INTEGER | 否 | — | I | 正文 UTF-16 偏移 |
| `range_length_utf16` | INTEGER | 否 | — | I | 正文 UTF-16 长度，codec 校验不截断字符 |

### 约束与索引

- 主键：`(message_local_id, ordinal)`。
- 外键：`(user_id)` → `user_profile(user_id)`；删除行为 `NO ACTION`。
- 外键：`(message_local_id)` → `message(local_id)`；删除行为 `CASCADE`。
- 检查约束：`(ordinal >= 0)`。
- 检查约束：`(mention_kind IN ('user','all'))`。
- 检查约束：`(range_start_utf16 >= 0)`。
- 检查约束：`(range_length_utf16 > 0)`。
- 检查约束：`((mention_kind = 'user' AND user_id IS NOT NULL) OR (mention_kind = 'all' AND user_id IS NULL))`。

### 典型访问与事务

- 查询：按 message_local_id、ordinal 获取正文实体；@我的消息后续增加专用索引前需量测。
- 写入边界：与正文同事务；codec 验证范围有效、不截断组合字符和 mention_kind 对应的用户值。

## 12. media_asset：逻辑媒体

一个逻辑附件一行，可有多个物理资源并被多条消息／草稿引用。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `asset_id` | TEXT | 否 | — | I | 逻辑附件 UUID，同一资源允许被多个消息/草稿引用 |
| `kind` | TEXT | 否 | — | I | 逻辑媒体类型 |
| `metadata_json` | TEXT | 否 | `'{}'` | I | 尺寸、时长、文件名、波形等版本化元数据 |
| `metadata_version` | INTEGER | 否 | `1` | I | 元数据版本 |
| `created_at_ms` | INTEGER | 否 | — | L | 创建时间 |

### 约束与索引

- 主键：`(asset_id)`。
- 检查约束：`(kind IN ('image','video','audio','file','live_photo','link_preview'))`。
- 检查约束：`(metadata_version > 0)`。

### 典型访问与事务

- 查询：按 asset_id 批量读取；按引用表反查是否仍被使用。
- 写入边界：元数据在导入准备后与首次引用同事务写入；GC 通过协调器与引用写入互斥。

## 13. media_resource：物理资源

每个 asset 的每种 role 最多一行；Live Photo 的 original 与 paired_video 是两个资源。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `resource_id` | TEXT | 否 | — | I | 单一物理资源身份 |
| `asset_id` | TEXT | 否 | — | I | 所属逻辑附件 |
| `role` | TEXT | 否 | — | I | 原件、缩略图、配对视频或链接资源 |
| `relative_path` | TEXT | 是 | — | L | 账号密文文件相对路径；cache/ 映射到账号加密缓存目录 |
| `crypto_version` | INTEGER | 是 | — | L | 本地媒体信封版本；无本地文件时可空 |
| `key_id` | TEXT | 是 | — | L | 本地媒体密钥版本，值不含密钥 |
| `cipher_byte_count` | INTEGER | 是 | — | L | 本地密文文件长度；无本地文件时可空 |
| `remote_object_key` | TEXT | 是 | — | S | 可重新获取授权的对象键，禁止持久化临时签名 URL |
| `sha256` | TEXT | 是 | — | I | 校验摘要，未下载时可空；不作为跨账号共享标识 |
| `byte_count` | INTEGER | 是 | — | I | 逻辑原文长度，未知时为空；不同于磁盘密文长度 |
| `mime_type` | TEXT | 否 | — | I | 媒体 MIME 类型 |
| `local_state` | TEXT | 否 | `'absent'` | L | 本机文件状态 |
| `retention` | TEXT | 否 | — | L | 原件持久保存或可重建缓存 |

### 约束与索引

- 主键：`(resource_id)`。
- 唯一约束：`(asset_id, role)`。
- 唯一约束：`(relative_path)`。
- 外键：`(asset_id)` → `media_asset(asset_id)`；删除行为 `CASCADE`。
- 检查约束：`(role IN ('original','thumbnail','paired_video','cover','icon'))`。
- 检查约束：`(byte_count >= 0)`。
- 检查约束：`(local_state IN ('absent','staged','ready','missing','deleting'))`。
- 检查约束：`(retention IN ('durable','cache'))`。
- 检查约束：`(local_state != 'ready' OR (relative_path IS NOT NULL AND crypto_version IS NOT NULL AND key_id IS NOT NULL AND cipher_byte_count IS NOT NULL))`。
- 检查约束：`(crypto_version IS NULL OR crypto_version > 0)`；具体已支持格式由资源解密器校验，未知版本禁止解密。
- 检查约束：`(cipher_byte_count IS NULL OR cipher_byte_count > 0)`。
- 检查约束：`(relative_path IS NULL OR (substr(relative_path,1,1) != '/' AND relative_path NOT LIKE '../%' AND relative_path NOT LIKE '%/../%' AND relative_path NOT LIKE '%/..' AND relative_path != '..'))`。

### 典型访问与事务

- 查询：按 asset_id 取资源组；按 resource_id 点查传输对象；relative_path 唯一避免覆盖。
- 写入边界：密文先完成认证回读再提交 ready 引用，提交时核对信封 key_id／版本与行一致；下载恢复的状态与 transfer_job 完成同事务；路径检查必须叠加文件系统校验。

## 14. message_attachment：消息附件引用

每消息每 ordinal 一个逻辑附件，同一 asset 可被多个消息引用。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `message_local_id` | INTEGER | 否 | — | L | 所属消息 |
| `ordinal` | INTEGER | 否 | — | I | 媒体组内顺序，单附件为 0 |
| `asset_id` | TEXT | 否 | — | I | 被引用逻辑资源，禁止直接级联删除仍有引用的资源 |

### 约束与索引

- 主键：`(message_local_id, ordinal)`。
- 索引 `idx_message_attachment_asset`：`message_attachment(asset_id)`。用途见本表典型访问。
- 外键：`(asset_id)` → `media_asset(asset_id)`；删除行为 `NO ACTION`。
- 外键：`(message_local_id)` → `message(local_id)`；删除行为 `CASCADE`。
- 检查约束：`(ordinal >= 0)`。

### 典型访问与事务

- 查询：按 message_local_id、ordinal 取有序附件；GC 按 asset_id 查是否有引用。
- 写入边界：发送、导入历史和删除消息的同一事务中增减；移除引用不直接删除文件。

## 15. draft：会话草稿

每会话每设备一份；不在首期跨设备同步。空白正文仍可为有效草稿。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `conversation_id` | TEXT | 否 | — | I | 每会话一份本设备草稿 |
| `revision` | INTEGER | 否 | — | L | 与 conversation_local_state.draft_revision 相等的草稿修订号，由 Repository 保证 |
| `content_schema_version` | INTEGER | 否 | `1` | L | 草稿载荷版本 |
| `content_json` | TEXT | 否 | — | L | 富文本片段、引用、附件槽位及顺序，资源仅引用 asset_id |
| `updated_at_ms` | INTEGER | 否 | — | L | 最近保存时间 |

### 约束与索引

- 主键：`(conversation_id)`。
- 外键：`(conversation_id)` → `conversation(conversation_id)`；删除行为 `NO ACTION`。
- 检查约束：`(revision > 0)`。
- 检查约束：`(content_schema_version > 0)`。

### 典型访问与事务

- 查询：按 conversation_id 同时读取草稿及 local_state.draft_revision；即使没有草稿也返回当前 revision。
- 写入边界：expected_revision 必须匹配持久序列；草稿、附件引用和序列递增同事务；删除后不重置序列，发送只删除与输入时 revision 相同的草稿。

## 16. draft_attachment：草稿附件引用

每会话草稿的唯一槽位一行，正文载荷按 slot／asset_id 关联。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `conversation_id` | TEXT | 否 | — | I | 所属草稿 |
| `slot` | TEXT | 否 | — | L | 唯一槽位，如 segment:2、media:0、audio:0 |
| `asset_id` | TEXT | 否 | — | I | 草稿持有的逻辑附件 |

### 约束与索引

- 主键：`(conversation_id, slot)`。
- 索引 `idx_draft_attachment_asset`：`draft_attachment(asset_id)`。用途见本表典型访问。
- 外键：`(asset_id)` → `media_asset(asset_id)`；删除行为 `NO ACTION`。
- 外键：`(conversation_id)` → `draft(conversation_id)`；删除行为 `CASCADE`。

### 典型访问与事务

- 查询：按 conversation_id 取所有槽位，GC 按 asset_id 查询引用。
- 写入边界：与草稿内容一次替换，应用层校验 JSON 中引用与此表一致。

## 17. conversation_read_state：自己的阅读与未读摘要

每会话一行；本机意图与服务端确认分开保存，有效水位取最大值。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `conversation_id` | TEXT | 否 | — | I | 当前账号的会话阅读状态 |
| `local_read_through_seq` | INTEGER | 否 | `0` | L | 已在本机确认阅读的最高边界 |
| `confirmed_read_through_seq` | INTEGER | 否 | `0` | S | 服务端合并所有设备后的阅读边界 |
| `server_unread_count` | INTEGER | 否 | `0` | S | 权威未读摘要 |
| `summary_at_seq` | INTEGER | 否 | `0` | S | 摘要覆盖的会话消息上界 |
| `summary_read_through_seq` | INTEGER | 否 | `0` | S | 计算该摘要时的阅读边界 |
| `server_revision` | INTEGER | 否 | `0` | S | 未读摘要与确认水位的版本 |

### 约束与索引

- 主键：`(conversation_id)`。
- 外键：`(conversation_id)` → `conversation(conversation_id)`；删除行为 `NO ACTION`。
- 检查约束：`(local_read_through_seq >= 0)`。
- 检查约束：`(confirmed_read_through_seq >= 0)`。
- 检查约束：`(server_unread_count >= 0)`。
- 检查约束：`(summary_at_seq >= 0)`。
- 检查约束：`(summary_read_through_seq >= 0)`。
- 检查约束：`(server_revision >= 0)`。

### 典型访问与事务

- 查询：按会话读取水位和摘要，用 history_range 判断本机未读是否可精确校准。
- 写入边界：本机推进与阅读 outbox、未读投影同事务；服务端摘要按版本和覆盖水位合并。

## 18. member_receipt_cursor：用户回执水位

每会话每用户一行，服务端合并多个设备；不能替代群消息的接收范围。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `conversation_id` | TEXT | 否 | — | I | 所属会话 |
| `user_id` | TEXT | 否 | — | I | 对方用户身份，多设备在服务端合并 |
| `delivered_through_seq` | INTEGER | 否 | `0` | S | 已确认覆盖的送达水位，不是收到的最大乱序序号 |
| `read_through_seq` | INTEGER | 否 | `0` | S | 已读即隐含送达 |
| `server_revision` | INTEGER | 否 | — | S | 回执版本，群人数仍以消息摘要为准 |

### 约束与索引

- 主键：`(conversation_id, user_id)`。
- 外键：`(user_id)` → `user_profile(user_id)`；删除行为 `NO ACTION`。
- 外键：`(conversation_id)` → `conversation(conversation_id)`；删除行为 `NO ACTION`。
- 检查约束：`(delivered_through_seq >= 0)`。
- 检查约束：`(read_through_seq >= 0)`。
- 检查约束：`(server_revision >= 0)`。
- 检查约束：`(read_through_seq <= delivered_through_seq)`。

### 典型访问与事务

- 查询：私聊按会话＋对方用户读取，以消息 seq 与水位比较。
- 写入边界：按 server_revision 合并，强制 read<=delivered；群人数不从此表直接扫描所有成员推算。

## 19. message_receipt_summary：群消息回执摘要

一条发出消息一份权威人数与当前明细缓存状态；无行表示尚未知。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `message_local_id` | INTEGER | 否 | — | L | 对应已确认的发出消息 |
| `audience_version` | TEXT | 否 | — | S | 发送时有效接收范围版本，排除发送者 |
| `expected_count` | INTEGER | 否 | — | S | 应接收人数 |
| `delivered_count` | INTEGER | 否 | — | S | 已送达人数 |
| `read_count` | INTEGER | 否 | — | S | 已读人数 |
| `server_revision` | INTEGER | 否 | — | S | 权威统计版本，允许新版本纠正旧统计 |
| `detail_snapshot_token` | TEXT | 是 | — | S | 当前明细缓存所属快照，未获取为 NULL |
| `detail_next_cursor` | TEXT | 是 | — | S | 明细下一页，不以 NULL 单独判断是否已请求 |
| `detail_complete` | INTEGER | 否 | `0` | L | 当前快照明细是否完整 |

### 约束与索引

- 主键：`(message_local_id)`。
- 外键：`(message_local_id)` → `message(local_id)`；删除行为 `CASCADE`。
- 检查约束：`(expected_count >= 0)`。
- 检查约束：`(delivered_count >= 0)`。
- 检查约束：`(read_count >= 0)`。
- 检查约束：`(server_revision >= 0)`。
- 检查约束：`(detail_complete IN (0,1))`。
- 检查约束：`(read_count <= delivered_count AND delivered_count <= expected_count)`。

### 典型访问与事务

- 查询：按 message_local_id 获取人数，打开详情时使用 audience_version 和 detail token。
- 写入边界：新版本摘要与旧明细清除同事务；人数允许更高版本纠正，不盲目取 max。

## 20. message_receipt_detail：回执明细缓存

按需缓存一个消息快照下的用户状态；同一消息用户最多一行。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `message_local_id` | INTEGER | 否 | — | L | 明细只按需缓存 |
| `user_id` | TEXT | 否 | — | I | 接收用户 |
| `membership_id` | TEXT | 是 | — | S | 群成员当时的入群身份，允许本地没有此成员历史 |
| `snapshot_token` | TEXT | 否 | — | S | 必须与父摘要缓存快照一致，由 Repository 校验 |
| `state` | TEXT | 否 | — | S | 此快照的成员回执状态 |
| `delivered_at_ms` | INTEGER | 是 | — | S | 送达时间，可被服务端省略 |
| `read_at_ms` | INTEGER | 是 | — | S | 阅读时间，可被服务端省略 |

### 约束与索引

- 主键：`(message_local_id, user_id)`。
- 外键：`(user_id)` → `user_profile(user_id)`；删除行为 `NO ACTION`。
- 外键：`(message_local_id)` → `message_receipt_summary(message_local_id)`；删除行为 `CASCADE`。
- 检查约束：`(state IN ('pending','delivered','read'))`。

### 典型访问与事务

- 查询：按 message_local_id 分页读取缓存，继续网络分页使用父摘要 detail_next_cursor。
- 写入边界：写页时校验父 snapshot token 及 revision；明细和 next_cursor、complete 一起提交；不是所有消息的常驻扇出表。

## 21. message_tombstone：删除与撤回标记

每会话每消息 UUID 一行，可同时有本地删除和服务端撤回；目标消息可以不存在。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `conversation_id` | TEXT | 否 | — | I | 所属会话，先撤回可先创建占位会话 |
| `message_uuid` | TEXT | 否 | — | I | 消息可尚未下载，因此不外键关联 message |
| `is_locally_deleted` | INTEGER | 否 | `0` | L | 本设备永久隐藏此身份 |
| `revoked_revision` | INTEGER | 是 | — | S | 撤回版本，NULL 表示未收到撤回 |
| `server_seq` | INTEGER | 是 | — | S | 若已知则记录，便于清空区间处理 |
| `revoked_by_user_id` | TEXT | 是 | — | S | 撤回操作者，允许资料未同步 |
| `updated_at_ms` | INTEGER | 否 | — | L | 标记最近更新时间 |

### 约束与索引

- 主键：`(conversation_id, message_uuid)`。
- 外键：`(conversation_id)` → `conversation(conversation_id)`；删除行为 `NO ACTION`。
- 检查约束：`(is_locally_deleted IN (0,1))`。
- 检查约束：`(revoked_revision >= 0)`。
- 检查约束：`(server_seq > 0)`。
- 检查约束：`(is_locally_deleted = 1 OR revoked_revision IS NOT NULL)`。

### 典型访问与事务

- 查询：消息导入、显示、搜索回查以会话＋UUID 点查标记。
- 写入边界：标记与正文占位、摘要、未读、引用资源释放及搜索失效同事务；先到撤回也保留到后续正文到达。

## 22. sync_checkpoint：同步进度

每个独立同步流一行，v1 使用 account_events；历史分页不写这里。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `stream_key` | TEXT | 否 | — | I | v1 固定 account_events，未来业务独立命名同步流 |
| `epoch` | TEXT | 否 | — | S | 当前同步基线身份，不改变实体版本单调性 |
| `cursor` | TEXT | 是 | — | S | 不透明事件游标，禁止按消息序号构造 |
| `phase` | TEXT | 否 | — | L | 初始同步、增量或重建 |
| `snapshot_token` | TEXT | 是 | — | S | 全量快照 token，重建时绑定固定快照 |
| `snapshot_next_cursor` | TEXT | 是 | — | S | 重建分页位置，与业务写入同事务保存 |
| `updated_at_ms` | INTEGER | 否 | — | L | 最近成功提交时间 |

### 约束与索引

- 主键：`(stream_key)`。
- 检查约束：`(phase IN ('bootstrap','incremental','resync'))`。

### 典型访问与事务

- 查询：开始请求读 epoch 和 cursor；提交前比较请求基线是否仍匹配。
- 写入边界：整个批次实体和 checkpoint 原子提交；快照每页业务写入与 snapshot_next_cursor 原子提交。

## 23. history_range：历史覆盖区间

会话中已确认查询完整或不可恢复的闭区间；不等于每个整数 seq 都有消息。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `conversation_id` | TEXT | 否 | — | I | 所属会话 |
| `start_seq` | INTEGER | 否 | — | S | 已确认范围下界，闭区间 |
| `end_seq` | INTEGER | 否 | — | S | 已确认范围上界，闭区间 |
| `coverage` | TEXT | 否 | — | S | 已完整查询或服务端已无法提供 |
| `boundary_revision` | INTEGER | 否 | — | S | 历史访问范围版本，成员权限变化可能使其过期 |

### 约束与索引

- 主键：`(conversation_id, start_seq, end_seq)`。
- 外键：`(conversation_id)` → `conversation(conversation_id)`；删除行为 `NO ACTION`。
- 检查约束：`(start_seq > 0)`。
- 检查约束：`(end_seq >= start_seq)`。
- 检查约束：`(coverage IN ('complete','unavailable'))`。
- 检查约束：`(boundary_revision >= 0)`。

### 典型访问与事务

- 查询：按会话及序号区间判断缺口，在 boundary_revision 内归并覆盖。
- 写入边界：历史消息与覆盖范围同事务；Repository 处理区间重叠、拆分与权限版本变化，普通 CHECK 不足以禁止重叠。

## 24. outbox_operation：持久业务命令

每个幂等 send／read／revoke 命令一行，JSON 参数包含协议版本，不包含短期授权。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `operation_id` | TEXT | 否 | — | I | 服务端业务操作幂等身份，重试不变 |
| `dedupe_key` | TEXT | 否 | — | L | send:<uuid>、read:<conversation>:<seq>、revoke:<uuid> |
| `conversation_id` | TEXT | 否 | — | I | 所属会话 |
| `message_local_id` | INTEGER | 是 | — | L | 发送或撤回目标，read 操作为空 |
| `kind` | TEXT | 否 | — | I | 业务操作类型 |
| `payload_version` | INTEGER | 否 | `1` | I | 操作载荷版本 |
| `payload_json` | TEXT | 否 | — | L | 不可变命令参数，阅读操作包含 read_through_seq |
| `state` | TEXT | 否 | `'queued'` | L | 任务状态 |
| `attempt_count` | INTEGER | 否 | `0` | L | 已领取尝试次数 |
| `next_attempt_at_ms` | INTEGER | 否 | `0` | L | 下次可执行时间 |
| `lease_token` | TEXT | 是 | — | L | 每次领取的新令牌，防止旧任务回调覆盖 |
| `lease_expires_at_ms` | INTEGER | 是 | — | L | 领取租约截止时间 |
| `last_error_code` | TEXT | 是 | — | L | 最近错误分类 |
| `created_at_ms` | INTEGER | 否 | — | L | 创建时间 |

### 约束与索引

- 主键：`(operation_id)`。
- 索引 `idx_outbox_ready`：`outbox_operation(state, next_attempt_at_ms, operation_id)`。用途见本表典型访问。
- 唯一约束：`(dedupe_key)`。
- 外键：`(message_local_id, conversation_id)` → `message(local_id, conversation_id)`；删除行为 `NO ACTION`。
- 外键：`(conversation_id)` → `conversation(conversation_id)`；删除行为 `NO ACTION`。
- 检查约束：`(kind IN ('send','read','revoke'))`。
- 检查约束：`(payload_version > 0)`。
- 检查约束：`(state IN ('queued','running','retry_wait','succeeded','failed','cancelled'))`。
- 检查约束：`(attempt_count >= 0)`。
- 检查约束：`((kind = 'read' AND message_local_id IS NULL) OR (kind IN ('send','revoke') AND message_local_id IS NOT NULL))`。
- 检查约束：`((state = 'running' AND lease_token IS NOT NULL AND lease_expires_at_ms IS NOT NULL) OR (state != 'running' AND lease_token IS NULL AND lease_expires_at_ms IS NULL))`。

### 典型访问与事务

- 查询：按 state＋next_attempt_at_ms 领取任务；同会话发送按消息 local_id 判断前驱是否仍待处理。
- 写入边界：领取、续约、完成均以 lease_token 条件更新；创建 send 与消息同事务，网络在事务外。

## 25. transfer_job：资源传输任务

每资源每方向至多一行，重新建立传输递增 generation。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `job_id` | TEXT | 否 | — | L | 传输任务身份 |
| `resource_id` | TEXT | 否 | — | I | 单个物理资源，任务存在期间阻止资源回收 |
| `direction` | TEXT | 否 | — | L | 上传或下载 |
| `generation` | INTEGER | 否 | `1` | L | 每次明确重建任务递增，旧回调必须匹配 |
| `state` | TEXT | 否 | `'queued'` | L | 任务状态 |
| `attempt_count` | INTEGER | 否 | `0` | L | 尝试次数 |
| `next_attempt_at_ms` | INTEGER | 否 | `0` | L | 重试时间 |
| `lease_token` | TEXT | 是 | — | L | 本次领取令牌 |
| `lease_expires_at_ms` | INTEGER | 是 | — | L | 租约截止 |
| `resume_relative_path` | TEXT | 是 | — | L | 断点续传数据的受保护相对路径，不作为永久消息内容 |
| `last_error_code` | TEXT | 是 | — | L | 最近错误 |

### 约束与索引

- 主键：`(job_id)`。
- 索引 `idx_transfer_ready`：`transfer_job(state, next_attempt_at_ms, job_id)`。用途见本表典型访问。
- 唯一约束：`(resource_id, direction)`。
- 外键：`(resource_id)` → `media_resource(resource_id)`；删除行为 `NO ACTION`。
- 检查约束：`(direction IN ('upload','download'))`。
- 检查约束：`(generation > 0)`。
- 检查约束：`(state IN ('queued','running','retry_wait','succeeded','failed','cancelled'))`。
- 检查约束：`(attempt_count >= 0)`。
- 检查约束：`((state = 'running' AND lease_token IS NOT NULL AND lease_expires_at_ms IS NOT NULL) OR (state != 'running' AND lease_token IS NULL AND lease_expires_at_ms IS NULL))`。

### 典型访问与事务

- 查询：按 state＋next_attempt_at_ms 领取；按 resource_id＋direction 查重复任务。
- 写入边界：租约更新与资源状态、远程对象键一起提交；网络及文件字节操作在事务外。

## 26. maintenance_job：维护任务

每维护目的 dedupe_key 一行，payload 含版本和恢复进度。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `job_id` | TEXT | 否 | — | L | 维护任务身份 |
| `dedupe_key` | TEXT | 否 | — | L | 同一维护目的仅一条任务，如 gc:<asset> 或 search:rebuild |
| `kind` | TEXT | 否 | — | L | 回收、重建或缩略图任务 |
| `asset_id` | TEXT | 是 | — | L | 资源维护对象，索引重建时为空 |
| `payload_json` | TEXT | 否 | `'{}'` | L | 版本化任务进度及恢复参数 |
| `state` | TEXT | 否 | `'queued'` | L | 任务状态 |
| `attempt_count` | INTEGER | 否 | `0` | L | 尝试次数 |
| `next_attempt_at_ms` | INTEGER | 否 | `0` | L | 下次执行时间 |
| `lease_token` | TEXT | 是 | — | L | 领取令牌 |
| `lease_expires_at_ms` | INTEGER | 是 | — | L | 租约截止 |
| `last_error_code` | TEXT | 是 | — | L | 最近错误 |

### 约束与索引

- 主键：`(job_id)`。
- 索引 `idx_maintenance_ready`：`maintenance_job(state, next_attempt_at_ms, job_id)`。用途见本表典型访问。
- 唯一约束：`(dedupe_key)`。
- 外键：`(asset_id)` → `media_asset(asset_id)`；删除行为 `NO ACTION`。
- 检查约束：`(kind IN ('media_gc','search_rebuild','thumbnail'))`。
- 检查约束：`(state IN ('queued','running','retry_wait','succeeded','failed','cancelled'))`。
- 检查约束：`(attempt_count >= 0)`。
- 检查约束：`((kind = 'search_rebuild' AND asset_id IS NULL) OR (kind != 'search_rebuild' AND asset_id IS NOT NULL))`。
- 检查约束：`((state = 'running' AND lease_token IS NOT NULL AND lease_expires_at_ms IS NOT NULL) OR (state != 'running' AND lease_token IS NULL AND lease_expires_at_ms IS NULL))`。

### 典型访问与事务

- 查询：按状态和下次时间领取，resource 类任务以 asset_id 关联资源。
- 写入边界：GC 完成时先移除自身任务引用再删除资源；重建进度与相应批次索引修改同事务。

## 27. search_document：搜索投影

每种实体身份一行；消息投影强关联 local_id，联系人和会话由 Repository 核对类型。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `document_id` | INTEGER | 否 | 自动分配 | L | FTS rowid，与实体业务 ID 分离 |
| `entity_kind` | TEXT | 否 | — | P | 索引实体类别 |
| `entity_id` | TEXT | 否 | — | I | 消息 UUID、联系人用户 ID 或会话 ID，Repository 负责类型校验 |
| `conversation_id` | TEXT | 是 | — | P | 消息或会话搜索的过滤范围 |
| `message_local_id` | INTEGER | 是 | — | P | 消息关联，其他类型为空 |
| `source_revision` | INTEGER | 否 | — | P | 生成索引使用的实体内容版本 |
| `tokenizer_version` | INTEGER | 否 | `1` | P | 规范化及分词算法版本 |
| `normalized_text` | TEXT | 否 | — | P | 用于候选结果精确复核的规范化文本 |
| `search_tokens` | TEXT | 否 | — | P | 应用生成的编码 token，以 ASCII 空格分隔 |

### 约束与索引

- 主键：`(document_id)`。
- 索引 `idx_search_conversation`：`search_document(conversation_id, entity_kind)`。用途见本表典型访问。
- 唯一约束：`(entity_kind, entity_id)`。
- 唯一约束：`(message_local_id)`。
- 外键：`(message_local_id)` → `message(local_id)`；删除行为 `CASCADE`。
- 外键：`(conversation_id)` → `conversation(conversation_id)`；删除行为 `NO ACTION`。
- 检查约束：`(entity_kind IN ('message','contact','conversation'))`。
- 检查约束：`(source_revision >= 0)`。
- 检查约束：`(tokenizer_version > 0)`。
- 检查约束：`((entity_kind = 'message' AND message_local_id IS NOT NULL AND conversation_id IS NOT NULL) OR (entity_kind != 'message' AND message_local_id IS NULL))`。

### 典型访问与事务

- 查询：先 FTS 找 document_id，再回查主表、权限、删除和内容版本，过滤后再填满结果页。
- 写入边界：与 FTS 触发维护同事务；generation 匹配才提交；撤回或本地删除不能被旧任务恢复索引。

## 28. search_dirty：搜索失效队列

每实体一行最新失效；generation 从库级单调计数分配，避免行删除后的 ABA。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `entity_kind` | TEXT | 否 | — | L | 待更新实体类别 |
| `entity_id` | TEXT | 否 | — | I | 对应业务身份，删除后也须可记录 |
| `generation` | INTEGER | 否 | — | L | 每次失效递增，防止相同服务端版本的本地删除被旧任务覆盖 |
| `requested_at_ms` | INTEGER | 否 | — | L | 入队时间，用于分批调度 |

### 约束与索引

- 主键：`(entity_kind, entity_id)`。
- 检查约束：`(entity_kind IN ('message','contact','conversation'))`。
- 检查约束：`(generation > 0)`。

### 典型访问与事务

- 查询：按 requested_at_ms 小批量处理；首期队列规模有限，积压严重时再量测增加调度索引。
- 写入边界：业务变化、库级 generation 增加和 dirty upsert 同事务；成功更新投影后按 generation 条件删除。

## 29. legacy_import：旧草稿导入记录

每个旧清单身份一行，摘要用于识别已成功导入的源版本。

### 字段

| 字段 | SQLite 类型 | 可空 | 默认值 | 权威 | 中文说明 |
| --- | --- | --- | --- | --- | --- |
| `source_key` | TEXT | 否 | — | L | 旧草稿清单的稳定相对身份 |
| `source_digest` | TEXT | 否 | — | L | 已导入版本摘要，区分重复执行与旧清单更新 |
| `conversation_id` | TEXT | 否 | — | I | 仅指向 local-demo 命名空间中的目标会话 |
| `imported_at_ms` | INTEGER | 否 | — | L | 文件和草稿提交成功时间；此行与草稿同事务提交 |

### 约束与索引

- 主键：`(source_key)`。
- 外键：`(conversation_id)` → `conversation(conversation_id)`；删除行为 `NO ACTION`。

### 典型访问与事务

- 查询：按 source_key 检查摘要；命中相同摘要跳过，有新目标草稿时不覆盖。
- 写入边界：草稿、资源引用和导入标记同事务；仅 local-demo 账号使用，迁移失败不得提前标记。

## 30. search_fts：全文索引虚拟表

每个 `search_document.document_id` 对应一个 FTS rowid。唯一索引列为 `search_tokens`，逻辑类型 TEXT，不单独施加普通表 NOT NULL 或外键；外部内容表为 search_document，content_rowid 为 document_id，分词器为 ascii。SQLite 生成的 shadow 表不属于业务接口，不能直接读写。

维护触发器名称约定为 `search_document_ai`、`search_document_ad`、`search_document_au`：分别在投影插入后写索引、删除后移除旧 token、更新后先移除旧 token 再加入新 token。触发器只连接搜索投影和 FTS，不负责业务消息的同步逻辑。重建必须通过受控重建流程，普通业务不得直接修改 search_fts。

典型访问：使用预编码 token 进行 MATCH，取得 rowid 后关联 search_document，再回查 message 及删除边界。关键词必须参数绑定且只允许应用生成的 token 运算组合；不把用户输入直接拼入 MATCH。查询页过滤掉无效候选后继续扫描候选填满页面，不能固定取前 N 个候选过滤后就声称无更多结果。

## 31. 关键查询与索引验收

| 查询 | 过滤／顺序 | 预期索引 |
| --- | --- | --- |
| 已确认历史 | conversation_id 相等、server_seq 非空且小于游标；server_seq DESC | idx_message_sequence |
| 待确认消息 | conversation_id 相等、server_seq 为空；anchor_server_seq、local_id | idx_message_pending |
| 会话列表 | is_hidden=0；is_pinned DESC、activity_at_ms DESC、conversation_id | idx_conversation_list |
| 重复客户端消息 | sender_id＋非空 client_message_id | idx_message_client |
| 重复服务端消息 | conversation_id＋非空 server_message_id | idx_message_server |
| 当前群成员 | conversation_id、left_seq 为空 | idx_membership_active |
| 持久任务领取 | 单一可领取 state、next_attempt_at_ms 不晚于当前时间 | 对应 idx_*_ready |
| 资源回收判断 | asset_id 反查消息和草稿引用 | idx_message_attachment_asset、idx_draft_attachment_asset |
| 撤回引用快照 | conversation_id＋target_message_uuid | idx_relation_target |
| 全文搜索 | FTS MATCH → 投影 → 主表安全过滤 | FTS 虚拟索引＋相关实体主键 |

复合分页游标应包含完整排序元组，不能只存 activity_at_ms 导致同时间会话漏页。任务的 queued 与 retry_wait 可分别查询再合并，避免假设 IN 条件总能保持索引顺序。页面性能是否满足要求必须依据 EXPLAIN QUERY PLAN 和真机测量，本文只规定预期。

## 32. 数据库约束之外的领域校验

- 一条已确认消息的 server_seq、server_message_id、会话、发送者和 UUID 不可被普通更新改写；未知目标资料可以占位，身份不能伪造。
- 每个可见消息必须有 payload；已知 payload 的媒体、引用和 @ 索引要与关系表一致，@ 范围必须落在纯文本内。
- conversation_local_state.last_message_local_id 必须可见；外键只保证属于同一会话，不能证明未被清空或撤回。
- chat_group 所属会话必须 kind=group；membership 的退出区间不能重叠，回执明细快照必须与父摘要匹配。
- history_range 必须按同版本规范化为不冲突区间；SQLite PK 不能阻止不同起止区间相互重叠。
- search_document 的 entity_id、message_local_id、conversation_id 必须对应同一实体；主表身份关系变更后投影必须失效。
- maintenance_job.payload_json 顶层包含任务版本；路径、资源状态、文件存在和访问租约须由账号资源协调器验证。

## 33. 后续扩展与迁移账本

首期物理迁移账本由 GRDB DatabaseMigrator 管理，不在本字典手写其内部表。收藏、表情、回应、置顶、公告、编辑历史和翻译表均在相应业务启动时独立设计，见 [扩展边界](architecture.md)。新增强资源引用时必须同时扩展 GC 判断；新增内容版本必须同步更新 [协议](sync-contract.md)、codec 和搜索失效策略。
