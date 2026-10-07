# 账号基线表结构与字段字典

当前唯一基线：`account-storage-v1`。本文列出实际创建的表；来源为 [ChatSchema](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/ChatSchema.swift) 和 [AccountDatabase](../../SharePackage/AzureFishStorage/Sources/AzureFishStorage/AccountDatabase.swift)。不预建未接入业务。返回[入口](README.md)。

## 约定与职责

所有表名使用单数 snake_case；Record 的 CodingKeys 与 Columns 使用同一物理列名。主键与外键通过 GRDB schema API 创建，不使用 replace 冲突策略。`position` 从 0 开始，保留数组次序与重复元素；主键中的 position 是元素位置而不是业务身份。

- 账号身份、配置：`account_store_identity`、`account_local_preference`。
- 用户与关系：`user_profile` 是资料投影，`contact_relationship` 是本人视角关系；申请与可用动作独立。
- 会话：成员、成员有效区间、已读水位、本机状态与本机偏好各按自己的版本和生命周期维护。
- 消息：`message` 保存稳定身份与顺序；正文按类型，媒体用 `message_attachment`；最新摘要使用独立 `conversation_message_summary` 聚合及自己的内容子表，不等于已加载历史。
- 媒体：`media_asset` 按业务 ID 与版本存快照，`media_resource` 仅保存物理资源描述。资源角色和顺序属于引用关系；尺寸、时长和动画属性属于 asset 几何元数据，波形为按位置子表。
- 草稿／展示：根、语义片段、格式、附件、媒体条目、波形分别建表；slot 区分 document、media、audio。旧系统编辑器的上传附件使用独立草稿上传关系，不混入上传任务。
- 发送／上传：稳定身份、排序、内容片段、附件与本机资源引用独立保存。发送状态更新不能替换命令内容；上传进度不能清除取消标记。
- 同步／恢复：检查点、历史覆盖、私聊解析、原始联系人请求和撤回恢复各有专用接口。

消息内容表以 message_id 为主键和父外键，没有重复 content_id。`kind` 和 `schema_version` 保留服务端原值；未知类型或未来版本使用 unknown_content 保留当前 DTO 已收到的 text、link 等字段，其他已接收关联仍逐表保留。已知媒体无需独立重复文件路径的消息表。

弱关联边界：隐藏状态、临时私聊草稿、展示／转写缓存可以先于权威会话或消息到达，不要求权威实体父行。已知聚合内部有强外键并级联删除。资源 UUID 可在本机已加密但尚无远端描述时被草稿引用，因此草稿资源字段不强制已有远端资源元数据。数据库不存物理表名关联，不存页面明文路径。

SQL INTEGER 用于整数、布尔和毫秒时间戳（服务端定义）；任务 created_at／恢复 expires 使用 Unix 秒 REAL；编辑器 duration 是秒，尺寸是像素。UInt64 草稿 revision 以十进制 TEXT 无损保存。可空字段的 NULL 与空字符串不同；has_text_runs 区分 nil 和空数组。

## account_store_identity

单行主键 id=1，校验打开范围。字段：`id INTEGER PRIMARY KEY`、`environment TEXT NOT NULL`、`user_id TEXT NOT NULL`。不代替 GRDB 自己的迁移账本。

## user_profile

Record：[ UserProfileRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/UserProfileRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `id` | TEXT | 主键 |
| `nickname` | TEXT | NOT NULL |
| `version` | INTEGER | NOT NULL |
| `avatar_id` | TEXT | 可空 |
| `deleted` | INTEGER | 可空 |

## contact_relationship

Record：[ ContactRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/ContactRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `peer_id` | TEXT | 主键；外键 user_profile.id，ON DELETE CASCADE |
| `id` | TEXT | NOT NULL |
| `state` | TEXT | NOT NULL |
| `requester_id` | TEXT | NOT NULL |
| `revision` | INTEGER | NOT NULL |
| `updated_at` | INTEGER | NOT NULL |
| `semantics_version` | INTEGER | NOT NULL |
| `is_contact` | INTEGER | NOT NULL |
| `remark` | TEXT | NOT NULL |
| `is_blocked` | INTEGER | NOT NULL |

## contact_request

Record：[ ContactRequestRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/ContactRequestRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `peer_id` | TEXT | 主键；外键 contact_relationship.peer_id，ON DELETE CASCADE |
| `request_id` | TEXT | NOT NULL |
| `state` | TEXT | NOT NULL |
| `message` | TEXT | NOT NULL |
| `updated_at` | INTEGER | NOT NULL |

## contact_available_action

Record：[ ContactActionRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/ContactActionRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `peer_id` | TEXT | NOT NULL；外键 contact_relationship.peer_id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `action` | TEXT | NOT NULL |

组合主键：`peer_id`, `position`。

## conversation

Record：[ ConversationRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/ConversationRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `id` | TEXT | 主键 |
| `kind` | TEXT | NOT NULL |
| `title` | TEXT | NOT NULL |
| `owner_id` | TEXT | NOT NULL |
| `revision` | INTEGER | NOT NULL |
| `boundary_revision` | INTEGER | NOT NULL |
| `latest` | INTEGER | NOT NULL |
| `closed` | INTEGER | NOT NULL |

## conversation_member

Record：[ MemberRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/MemberRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `conversation_id` | TEXT | NOT NULL；外键 conversation.id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `user_id` | TEXT | NOT NULL |
| `active` | INTEGER | NOT NULL |

组合主键：`conversation_id`, `position`。

## conversation_member_interval

Record：[ MemberIntervalRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/MemberIntervalRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `conversation_id` | TEXT | NOT NULL；外键 conversation.id，ON DELETE CASCADE |
| `member_position` | INTEGER | NOT NULL |
| `position` | INTEGER | NOT NULL |
| `joined` | INTEGER | NOT NULL |
| `left` | INTEGER | NOT NULL |

组合主键：`conversation_id`, `member_position`, `position`。

组合外键：(`conversation_id`, `member_position`) → `conversation_member` (`conversation_id`, `position`)，ON DELETE CASCADE。

## conversation_read_state

Record：[ ReadStateRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/ReadStateRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `conversation_id` | TEXT | 主键；外键 conversation.id，ON DELETE CASCADE |
| `read` | INTEGER | NOT NULL |
| `delivered` | INTEGER | NOT NULL |
| `unread` | INTEGER | NOT NULL |
| `through` | INTEGER | NOT NULL |
| `revision` | INTEGER | NOT NULL |

## conversation_local_state

Record：[ LocalStateRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/LocalStateRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `conversation_id` | TEXT | 主键 |
| `appeared` | INTEGER | NOT NULL |
| `hidden_through` | INTEGER | 可空 |
| `manually_unread` | INTEGER | NOT NULL |
| `activity_at` | INTEGER | NOT NULL |
| `inspected_through` | INTEGER | NOT NULL |
| `inspected_boundary` | INTEGER | NOT NULL |
| `cleared_through` | INTEGER | NOT NULL |

## conversation_local_preference

Record：[ PreferenceRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/PreferenceRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `conversation_id` | TEXT | 主键 |
| `is_pinned` | INTEGER | NOT NULL |
| `is_muted` | INTEGER | NOT NULL |

## account_local_preference

Record：[ AccountPreferenceRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/AccountPreferenceRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `id` | INTEGER | 主键 |
| `pinned_collapsed` | INTEGER | NOT NULL |

## sync_checkpoint

Record：[ CheckpointRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/CheckpointRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `stream` | TEXT | 主键 |
| `cursor` | TEXT | NOT NULL |
| `epoch` | TEXT | NOT NULL |

## message_local_state

Record：[ HiddenRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/HiddenRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | 主键 |
| `hidden` | INTEGER | NOT NULL |

## conversation_history_range

Record：[ HistoryRangeRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/HistoryRangeRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `id` | INTEGER | 主键，自增 |
| `conversation_id` | TEXT | NOT NULL |
| `boundary` | INTEGER | NOT NULL |
| `lower` | INTEGER | NOT NULL |
| `upper` | INTEGER | NOT NULL |

索引 `idx_conversation_history_range_0`：`conversation_id`, `boundary`, `lower`。

## media_asset

Record：[ AssetRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/AssetRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `key` | TEXT | 主键 |
| `id` | TEXT | NOT NULL |
| `kind` | TEXT | NOT NULL |
| `version` | INTEGER | NOT NULL |

## media_asset_geometry

Record：[ AssetGeometryRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/AssetGeometryRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `asset_key` | TEXT | 主键；外键 media_asset.key，ON DELETE CASCADE |
| `width` | INTEGER | NOT NULL |
| `height` | INTEGER | NOT NULL |
| `duration` | INTEGER | NOT NULL |
| `animated` | INTEGER | NOT NULL |

## media_asset_waveform

Record：[ AssetWaveRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/AssetWaveRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `asset_key` | TEXT | NOT NULL；外键 media_asset.key，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `value` | DOUBLE | NOT NULL |

组合主键：`asset_key`, `position`。

## media_resource

Record：[ ResourceRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/ResourceRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `id` | TEXT | 主键 |
| `filename` | TEXT | NOT NULL |
| `mime` | TEXT | NOT NULL |
| `bytes` | INTEGER | NOT NULL |
| `sha256` | TEXT | NOT NULL |

## media_asset_resource

Record：[ AssetResourceRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/AssetResourceRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `asset_key` | TEXT | NOT NULL；外键 media_asset.key，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `resource_id` | TEXT | NOT NULL；外键 media_resource.id |
| `role` | TEXT | NOT NULL |

组合主键：`asset_key`, `position`。

## message

Record：[ MessageRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/MessageRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `id` | TEXT | 主键 |
| `conversation_id` | TEXT | NOT NULL |
| `client_id` | TEXT | NOT NULL |
| `server_id` | TEXT | NOT NULL |
| `sender_id` | TEXT | NOT NULL |
| `device_id` | TEXT | NOT NULL |
| `sequence` | INTEGER | NOT NULL |
| `created_at` | INTEGER | NOT NULL |
| `revision` | INTEGER | NOT NULL |
| `kind` | TEXT | NOT NULL |
| `schema_version` | INTEGER | NOT NULL |
| `revoked` | INTEGER | NOT NULL |
| `has_text_runs` | INTEGER | NOT NULL |

索引 `idx_message_0`：`conversation_id`, `sequence`。

索引 `idx_message_1`：`conversation_id`, `created_at`, `id`。

## message_text_content

Record：[ MessageTextRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/MessageTextRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | 主键；外键 message.id，ON DELETE CASCADE |
| `text` | TEXT | NOT NULL |

## message_link_content

Record：[ MessageLinkRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/MessageLinkRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | 主键；外键 message.id，ON DELETE CASCADE |
| `text` | TEXT | NOT NULL |
| `url` | TEXT | 可空 |

## message_unrecognized_content

Record：[ MessageUnknownRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/MessageUnknownRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | 主键；外键 message.id，ON DELETE CASCADE |
| `text` | TEXT | NOT NULL |
| `link_url` | TEXT | 可空 |

## message_system_content

Record：[ MessageSystemRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/MessageSystemRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | 主键；外键 message.id，ON DELETE CASCADE |
| `kind` | TEXT | NOT NULL |
| `relationship_id` | TEXT | NOT NULL |
| `relationship_revision` | INTEGER | NOT NULL |
| `requester_id` | TEXT | NOT NULL |
| `accepter_id` | TEXT | NOT NULL |

## message_text_run

Record：[ MessageRunRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/MessageRunRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | NOT NULL；外键 message.id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `text` | TEXT | NOT NULL |
| `style` | INTEGER | NOT NULL |

组合主键：`message_id`, `position`。

## message_receipt_summary

Record：[ MessageReceiptRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/MessageReceiptRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | 主键；外键 message.id，ON DELETE CASCADE |
| `expected` | INTEGER | NOT NULL |
| `delivered` | INTEGER | NOT NULL |
| `read` | INTEGER | NOT NULL |
| `revision` | INTEGER | NOT NULL |

## message_attachment

Record：[ MessageAttachmentRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/MessageAttachmentRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | NOT NULL；外键 message.id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `asset_key` | TEXT | NOT NULL |

组合主键：`message_id`, `position`。

## conversation_message_summary

Record：[ SummaryRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/SummaryRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `id` | TEXT | 主键 |
| `conversation_id` | TEXT | NOT NULL；UNIQUE |
| `client_id` | TEXT | NOT NULL |
| `server_id` | TEXT | NOT NULL |
| `sender_id` | TEXT | NOT NULL |
| `device_id` | TEXT | NOT NULL |
| `sequence` | INTEGER | NOT NULL |
| `created_at` | INTEGER | NOT NULL |
| `revision` | INTEGER | NOT NULL |
| `kind` | TEXT | NOT NULL |
| `schema_version` | INTEGER | NOT NULL |
| `revoked` | INTEGER | NOT NULL |
| `has_text_runs` | INTEGER | NOT NULL |

索引 `idx_conversation_message_summary_0`：`conversation_id`, `sequence`。

索引 `idx_conversation_message_summary_1`：`conversation_id`, `created_at`, `id`。

## conversation_message_summary_text_content

Record：[ SummaryTextRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/SummaryTextRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | 主键；外键 conversation_message_summary.id，ON DELETE CASCADE |
| `text` | TEXT | NOT NULL |

## conversation_message_summary_link_content

Record：[ SummaryLinkRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/SummaryLinkRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | 主键；外键 conversation_message_summary.id，ON DELETE CASCADE |
| `text` | TEXT | NOT NULL |
| `url` | TEXT | 可空 |

## conversation_message_summary_unrecognized_content

Record：[ SummaryUnknownRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/SummaryUnknownRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | 主键；外键 conversation_message_summary.id，ON DELETE CASCADE |
| `text` | TEXT | NOT NULL |
| `link_url` | TEXT | 可空 |

## conversation_message_summary_system_content

Record：[ SummarySystemRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/SummarySystemRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | 主键；外键 conversation_message_summary.id，ON DELETE CASCADE |
| `kind` | TEXT | NOT NULL |
| `relationship_id` | TEXT | NOT NULL |
| `relationship_revision` | INTEGER | NOT NULL |
| `requester_id` | TEXT | NOT NULL |
| `accepter_id` | TEXT | NOT NULL |

## conversation_message_summary_text_run

Record：[ SummaryRunRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/SummaryRunRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | NOT NULL；外键 conversation_message_summary.id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `text` | TEXT | NOT NULL |
| `style` | INTEGER | NOT NULL |

组合主键：`message_id`, `position`。

## conversation_message_summary_receipt_summary

Record：[ SummaryReceiptRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/SummaryReceiptRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | 主键；外键 conversation_message_summary.id，ON DELETE CASCADE |
| `expected` | INTEGER | NOT NULL |
| `delivered` | INTEGER | NOT NULL |
| `read` | INTEGER | NOT NULL |
| `revision` | INTEGER | NOT NULL |

## conversation_message_summary_attachment

Record：[ SummaryAttachmentRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/SummaryAttachmentRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | NOT NULL；外键 conversation_message_summary.id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `asset_key` | TEXT | NOT NULL |

组合主键：`message_id`, `position`。

## message_send_task

Record：[ SendTaskRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/SendTaskRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `id` | TEXT | 主键 |
| `conversation_id` | TEXT | NOT NULL |
| `client_id` | TEXT | NOT NULL |
| `operation_id` | TEXT | NOT NULL |
| `device_id` | TEXT | NOT NULL |
| `kind` | TEXT | NOT NULL |
| `text` | TEXT | NOT NULL |
| `link_url` | TEXT | 可空 |
| `has_text_runs` | INTEGER | NOT NULL |
| `state` | TEXT | NOT NULL |
| `created_at` | DOUBLE | NOT NULL |
| `failure` | TEXT | 可空 |

## message_send_task_text_run

Record：[ SendRunRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/SendRunRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | NOT NULL；外键 message_send_task.id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `text` | TEXT | NOT NULL |
| `style` | INTEGER | NOT NULL |

组合主键：`message_id`, `position`。

## message_send_task_attachment

Record：[ SendAssetRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/SendAssetRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | NOT NULL；外键 message_send_task.id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `asset_id` | TEXT | NOT NULL |

组合主键：`message_id`, `position`。

## message_send_task_resource

Record：[ SendResourceRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/SendResourceRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | NOT NULL；外键 message_send_task.id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `resource_id` | TEXT | NOT NULL；外键 media_resource.id |

组合主键：`message_id`, `position`。

## conversation_send_order

Record：[ SendOrderRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/SendOrderRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `position` | INTEGER | 主键，自增 |
| `message_id` | TEXT | NOT NULL；UNIQUE |
| `conversation_id` | TEXT | NOT NULL |

索引 `idx_conversation_send_order_0`：`conversation_id`, `position`。

## media_upload_batch

Record：[ UploadBatchRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/UploadBatchRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `id` | TEXT | 主键 |
| `message_id` | TEXT | NOT NULL |
| `client_id` | TEXT | NOT NULL |
| `operation_id` | TEXT | NOT NULL |
| `device_id` | TEXT | NOT NULL |
| `created_at` | DOUBLE | NOT NULL |
| `conversation_id` | TEXT | NOT NULL |
| `kind` | TEXT | NOT NULL |
| `state` | TEXT | NOT NULL |
| `completed_bytes` | INTEGER | NOT NULL |
| `cancel_requested` | INTEGER | NOT NULL |

## media_upload_item

Record：[ UploadItemRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/UploadItemRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `owner_id` | TEXT | NOT NULL；外键 media_upload_batch.id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `id` | TEXT | NOT NULL |
| `kind` | TEXT | NOT NULL |
| `asset_id` | TEXT | 可空 |
| `complete_id` | TEXT | NOT NULL |
| `cancel_id` | TEXT | NOT NULL |

组合主键：`owner_id`, `position`。

## media_upload_resource

Record：[ UploadResourceRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/UploadResourceRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `owner_id` | TEXT | NOT NULL |
| `item_position` | INTEGER | NOT NULL |
| `position` | INTEGER | NOT NULL |
| `resource_id` | TEXT | NOT NULL；外键 media_resource.id |
| `role` | TEXT | NOT NULL |

组合主键：`owner_id`, `item_position`, `position`。

组合外键：(`owner_id`, `item_position`) → `media_upload_item` (`owner_id`, `position`)，ON DELETE CASCADE。

## conversation_draft

Record：[ DraftRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/DraftRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `conversation_id` | TEXT | 主键 |
| `text` | TEXT | NOT NULL |
| `has_editor` | INTEGER | NOT NULL |
| `version` | INTEGER | NOT NULL |
| `revision` | TEXT | NOT NULL |

## conversation_draft_asset

Record：[ DraftAssetRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/DraftAssetRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `conversation_id` | TEXT | NOT NULL；外键 conversation_draft.conversation_id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `asset_id` | TEXT | NOT NULL |

组合主键：`conversation_id`, `position`。

## conversation_draft_upload_item

Record：[ DraftUploadItemRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/DraftUploadItemRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `conversation_id` | TEXT | NOT NULL；外键 conversation_draft.conversation_id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `id` | TEXT | NOT NULL |
| `kind` | TEXT | NOT NULL |
| `asset_id` | TEXT | 可空 |
| `complete_id` | TEXT | NOT NULL |
| `cancel_id` | TEXT | NOT NULL |

组合主键：`conversation_id`, `position`。

## conversation_draft_upload_resource

Record：[ DraftUploadResourceRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/DraftUploadResourceRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `conversation_id` | TEXT | NOT NULL |
| `item_position` | INTEGER | NOT NULL |
| `position` | INTEGER | NOT NULL |
| `resource_id` | TEXT | NOT NULL；外键 media_resource.id |
| `role` | TEXT | NOT NULL |

组合主键：`conversation_id`, `item_position`, `position`。

组合外键：(`conversation_id`, `item_position`) → `conversation_draft_upload_item` (`conversation_id`, `position`)，ON DELETE CASCADE。

## direct_conversation_resolution

Record：[ ResolutionRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/ResolutionRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `local_id` | TEXT | 主键 |
| `operation_id` | TEXT | 可空 |
| `conversation_id` | TEXT | 可空 |
| `pending` | INTEGER | NOT NULL |

## contact_pending_operation

Record：[ ContactOperationRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/ContactOperationRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `peer_id` | TEXT | 主键 |
| `bytes` | BLOB | NOT NULL |
| `action` | TEXT | NOT NULL |
| `remark` | TEXT | NOT NULL |
| `message` | TEXT | NOT NULL |

## message_reedit_recovery

Record：[ ReeditRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/ReeditRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | 主键 |
| `conversation_id` | TEXT | NOT NULL |
| `operation_id` | TEXT | NOT NULL |
| `state` | TEXT | NOT NULL |
| `text` | TEXT | 可空 |
| `expires` | DOUBLE | NOT NULL |

## message_reedit_text_run

Record：[ ReeditRunRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/ReeditRunRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | NOT NULL；外键 message_reedit_recovery.message_id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `text` | TEXT | NOT NULL |
| `style` | INTEGER | NOT NULL |

组合主键：`message_id`, `position`。

## message_transcript_cache

Record：[ TranscriptRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/TranscriptRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | 主键 |
| `text` | TEXT | NOT NULL |

## message_presentation_cache

Record：[ PresentationRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/PresentationRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | 主键 |
| `conversation_id` | TEXT | NOT NULL |
| `version` | INTEGER | NOT NULL |
| `revision` | TEXT | NOT NULL |

## message_presentation_resource

Record：[ RetiredResourceRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/RetiredResourceRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `message_id` | TEXT | NOT NULL |
| `resource_id` | TEXT | NOT NULL |

组合主键：`message_id`, `resource_id`。

## media_cleanup_request

Record：[ CleanupRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/CleanupRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `resource_id` | TEXT | 主键 |

## conversation_draft_segment

Record：[ DraftSegmentRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/DraftSegmentRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `owner_id` | TEXT | NOT NULL；外键 conversation_draft.conversation_id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `kind` | TEXT | NOT NULL |
| `text` | TEXT | 可空 |
| `attachment_id` | TEXT | 可空 |

组合主键：`owner_id`, `position`。

## conversation_draft_segment_run

Record：[ DraftSegmentRunRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/DraftSegmentRunRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `owner_id` | TEXT | NOT NULL；外键 conversation_draft.conversation_id，ON DELETE CASCADE |
| `segment_position` | INTEGER | NOT NULL |
| `position` | INTEGER | NOT NULL |
| `text` | TEXT | NOT NULL |
| `style` | INTEGER | NOT NULL |

组合主键：`owner_id`, `segment_position`, `position`。

## conversation_draft_attachment

Record：[ DraftAttachmentRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/DraftAttachmentRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `owner_id` | TEXT | NOT NULL；外键 conversation_draft.conversation_id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `slot` | TEXT | NOT NULL |
| `id` | TEXT | NOT NULL |
| `kind` | TEXT | NOT NULL |
| `resource_id` | TEXT | 可空 |
| `thumbnail_id` | TEXT | 可空 |
| `icon_id` | TEXT | 可空 |
| `filename` | TEXT | 可空 |
| `type_identifier` | TEXT | 可空 |
| `byte_count` | INTEGER | 可空 |
| `url` | TEXT | 可空 |
| `title` | TEXT | 可空 |
| `duration` | DOUBLE | 可空 |
| `transcript` | TEXT | 可空 |

组合主键：`owner_id`, `position`。

## conversation_draft_media_item

Record：[ DraftMediaItemRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/DraftMediaItemRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `owner_id` | TEXT | NOT NULL；外键 conversation_draft.conversation_id，ON DELETE CASCADE |
| `attachment_position` | INTEGER | NOT NULL |
| `position` | INTEGER | NOT NULL |
| `id` | TEXT | NOT NULL |
| `asset_identifier` | TEXT | 可空 |
| `original_id` | TEXT | NOT NULL |
| `thumbnail_id` | TEXT | NOT NULL |
| `paired_video_id` | TEXT | 可空 |
| `width` | DOUBLE | NOT NULL |
| `height` | DOUBLE | NOT NULL |
| `duration` | DOUBLE | 可空 |
| `animated` | INTEGER | NOT NULL |

组合主键：`owner_id`, `attachment_position`, `position`。

## conversation_draft_waveform

Record：[ DraftWaveRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/DraftWaveRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `owner_id` | TEXT | NOT NULL；外键 conversation_draft.conversation_id，ON DELETE CASCADE |
| `attachment_position` | INTEGER | NOT NULL |
| `position` | INTEGER | NOT NULL |
| `value` | DOUBLE | NOT NULL |

组合主键：`owner_id`, `attachment_position`, `position`。

## message_presentation_segment

Record：[ PresentationSegmentRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/PresentationSegmentRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `owner_id` | TEXT | NOT NULL；外键 message_presentation_cache.message_id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `kind` | TEXT | NOT NULL |
| `text` | TEXT | 可空 |
| `attachment_id` | TEXT | 可空 |

组合主键：`owner_id`, `position`。

## message_presentation_segment_run

Record：[ PresentationSegmentRunRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/PresentationSegmentRunRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `owner_id` | TEXT | NOT NULL；外键 message_presentation_cache.message_id，ON DELETE CASCADE |
| `segment_position` | INTEGER | NOT NULL |
| `position` | INTEGER | NOT NULL |
| `text` | TEXT | NOT NULL |
| `style` | INTEGER | NOT NULL |

组合主键：`owner_id`, `segment_position`, `position`。

## message_presentation_attachment

Record：[ PresentationAttachmentRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/PresentationAttachmentRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `owner_id` | TEXT | NOT NULL；外键 message_presentation_cache.message_id，ON DELETE CASCADE |
| `position` | INTEGER | NOT NULL |
| `slot` | TEXT | NOT NULL |
| `id` | TEXT | NOT NULL |
| `kind` | TEXT | NOT NULL |
| `resource_id` | TEXT | 可空 |
| `thumbnail_id` | TEXT | 可空 |
| `icon_id` | TEXT | 可空 |
| `filename` | TEXT | 可空 |
| `type_identifier` | TEXT | 可空 |
| `byte_count` | INTEGER | 可空 |
| `url` | TEXT | 可空 |
| `title` | TEXT | 可空 |
| `duration` | DOUBLE | 可空 |
| `transcript` | TEXT | 可空 |

组合主键：`owner_id`, `position`。

## message_presentation_media_item

Record：[ PresentationMediaItemRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/PresentationMediaItemRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `owner_id` | TEXT | NOT NULL；外键 message_presentation_cache.message_id，ON DELETE CASCADE |
| `attachment_position` | INTEGER | NOT NULL |
| `position` | INTEGER | NOT NULL |
| `id` | TEXT | NOT NULL |
| `asset_identifier` | TEXT | 可空 |
| `original_id` | TEXT | NOT NULL |
| `thumbnail_id` | TEXT | NOT NULL |
| `paired_video_id` | TEXT | 可空 |
| `width` | DOUBLE | NOT NULL |
| `height` | DOUBLE | NOT NULL |
| `duration` | DOUBLE | 可空 |
| `animated` | INTEGER | NOT NULL |

组合主键：`owner_id`, `attachment_position`, `position`。

## message_presentation_waveform

Record：[ PresentationWaveRecord ](../../SharePackage/AzureFishChat/Sources/AzureFishChat/Storage/PresentationWaveRecord.swift)。

| 字段 | SQLite 类型 | 约束 |
| --- | --- | --- |
| `owner_id` | TEXT | NOT NULL；外键 message_presentation_cache.message_id，ON DELETE CASCADE |
| `attachment_position` | INTEGER | NOT NULL |
| `position` | INTEGER | NOT NULL |
| `value` | DOUBLE | NOT NULL |

组合主键：`owner_id`, `attachment_position`, `position`。

## message_search

同库 FTS5 虚表，`id` 是不索引的消息身份，`body` 是规范化后的 ASCII token，tokenizer 为 ascii。正文权威仍来自类型化内容表，候选必须回查隐藏、撤回和成员区间。FTS 的内部 shadow tables 由 SQLite 管理。

## 事务校验与未来结构

SQLite 外键不能要求每个父行一定有正文子行，Repository 在事务内成组维护，并在读取缺失必要子记录时报告不可用。版本、稳定身份、上传取消、资源描述摘要冲突和历史范围有效性由业务事务校验。主键／外键不能替代版本合并规则。

扩展应增加新的领域表、引用和有序迁移；无需更改既有消息身份。当前没有通用 meta、entity JSON、动态 content_table、泛型上传载荷，也没有未上线业务空表。搜索后台重建、容量索引调整等须根据真实测量另行迁移。

## 追加迁移：chat-media-import-v1

来源为 [ChatStore+MediaImports](../../SharePackage/AzureFishChat/Sources/AzureFishChat/ChatStore+MediaImports.swift)，沿用当前 SQLCipher 加密库。创建 `media_import_resource`，联合主键为 `(batch, resource_id)`，两个 TEXT 字段均非空。

| 字段 | 含义 |
| --- | --- |
| batch | 当前导入批次 UUID；同批资源合并提交或补偿 |
| resource_id | 开始写文件之前登记的资源 UUID；也可登记需要保留到提交结束的复用资源 |

完成事务将资源加入 `media_cleanup_request` 后删除对应日志。最终是否删除仍检查全部业务引用；日志不是业务附件表，不存页面 URL 或明文正文。
