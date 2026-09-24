# 聊天数据库开发设计

> **状态：设计阶段，尚未接入应用。** 本目录仅交付中文 Markdown 开发文档，不包含数据库实现、迁移脚本或 Swift 代码。更新日期：2026-09-24。

## 已确认的设计决策

| 项目 | 决策 |
| --- | --- |
| 设计范围 | AzureFish 客户端本地数据库，以及未来服务端必须满足的同步契约 |
| 技术方向 | GRDB／SQLCipher 加密 SQLite，远程依赖集成需先验证；具体集成在实施阶段验证 |
| 平台 | 存储层最低 iOS 15，与 iOS 26+ 聊天 UI 解耦 |
| 数据隔离 | 每个服务环境、账号独立数据库和媒体目录 |
| 首期业务 | 私聊、群聊、联系人、会话、多媒体、草稿、离线重试、撤回、未读、搜索 |
| 回执 | 私聊显示送达／已读；群聊支持人数及成员明细 |
| 历史 | 支持服务端保留范围内的历史漫游；本地记录长期保存 |
| 保护方式 | SQLCipher 整库＋媒体 AES-GCM＋iOS Data Protection；不声明端到端加密 |
| 容量基线 | 每账号百万条本地消息、单群最多 500 人；是待验证目标，不是已通过的指标 |
| 后续方向 | 收藏、表情、编辑、回应、置顶、群公告、翻译及独立社交模块 |

加密、密钥、备份与临时文件的权威规则见 [安全设计](../Security/README.md)；本文业务表留在一个加密库，不能另建明文 FTS 或资料缓存。

## 阅读顺序

1. [整体架构与扩展边界](architecture.md)：模块职责、数据流、实体关系和分库依据。
2. [表结构与字段字典](schema.md)：完整首期实体、字段、约束、索引、状态及典型访问。
3. [客户端与服务端同步契约](sync-contract.md)：拟定协议、消息身份、排序、幂等、历史及回执。
4. [生命周期与迁移](lifecycle-and-migration.md)：账号切换、媒体所有权、草稿迁移、任务恢复、搜索及故障处理。
5. [开发验证与验收](validation.md)：实施顺序、测试矩阵、容量测量，以及本次文档检查的证据边界。

字段定义以 `schema.md` 为准；跨实体行为以 `sync-contract.md` 和 `lifecycle-and-migration.md` 为准。新增业务时需要同时检查这些契约，不能只增加一个字段或一张表。文件名不带日期，便于持续维护；重大设计变化在本页追加决策记录。

## 当前工程与设计的区别

整体开发顺序已调整为“账号与用户资料 → 客户端认证接入 → IM”。本目录的“首期”指未来 IM 本地存储首期，并非当前账号服务首期承诺。认证身份来自独立 AzureFishServer；阅读 [客户端认证入口](../Authentication/README.md) 和 [服务端协议权威文档](../../AzureFishServer/Documentation/protobuf-contract.md)。服务端独立 SQLite 保存全体用户权威资料，本目录 GRDB 库仅保存当前设备、当前账号的数据，二者不共享文件。

当前聊天消息由 `ChatViewModel` 的内存数组管理，发送和历史仍为本地模拟；`Message.id` 是页面模型分配的整数，附件原件由页面临时存储拥有。现有 `ChatDraftStore` 已保存草稿清单及资源副本，但尚无真实账号隔离。本目录描述的是未来持久化架构，不能据此推断相关功能已存在。

实际代码入口见 [ChatViewModel](../../AzureFish/Features/Chat/ViewModels/ChatViewModel.swift)、[消息模型](../../AzureFish/Features/Chat/Models/Message.swift)、[页面附件存储](../../AzureFish/Features/Chat/Support/AttachmentStore.swift) 和 [草稿存储](../../AzureFish/Features/Chat/Support/ChatDraftStore.swift)。

## 决策记录

| 日期 | 决策 | 原因 |
| --- | --- | --- |
| 2026-09-24 | 安全补充：启用 SQLCipher 与独立媒体加密 | 替代此前仅系统文件保护的决策；密钥与库按账号隔离 |
| 2026-09-24 | 首期一个账号业务库，FTS 同库，媒体文件在库外 | 消息、会话摘要、删除、资源引用和任务保持单事务一致 |
| 2026-09-24 | 消息信封＋版本化 payload＋结构化关系表 | 保持查询字段可索引，同时兼容未知消息类型和业务扩展 |
| 2026-09-24 | 群回执摘要常驻、明细按需缓存 | 避免按消息数乘以群人数建立全量回执记录 |
| 2026-09-24 | 本次只交付 Markdown | 按用户最新要求，SQL、Swift、依赖接入和应用验证均留待实施阶段 |
| 2026-09-24 | 独立 Swift 服务端先实现认证；网络采用 Protobuf | 本地 payload JSON 与传输协议显式转换；IM 操作仍是后续拟定契约 |

## 参考与适用范围

- 用户提供的 `AppleIM/mobile_wechat_database_design_field_comments.md`：作为设计素材，未修改原文；没有将其中的建议当作必须照搬的实现要求。
- [GRDB 官方文档](https://github.com/groue/GRDB.swift)：连接池、事务、观察、迁移和 SQLCipher 接入说明。
- [GRDB 7.11.1](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1)：本轮核对的选型基线，尚未添加到工程依赖。
- [SQLite 外键](https://www.sqlite.org/foreignkeys.html)、[WAL](https://www.sqlite.org/wal.html)、[FTS5](https://www.sqlite.org/fts5.html)：实施阶段仍需在最低支持的 iOS SQLite 环境核对能力。
- [Apple 文件保护](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files)：本地数据保护的系统能力边界。

这是面向 AzureFish 的自研 IM 架构，不是微信官方数据库结构或兼容格式。
