# 账号业务存储

> **状态：已接入代码，验收结果见 [验证记录](validation.md)。** 当前基线为 `account-storage-v1`；旧开发库明确拒绝打开。本目录描述客户端实际存储，未来能力单独标注。

AzureFishStorage 提供每环境、每账号的 SQLCipher 数据库和 AES-GCM 媒体存储。AzureFishChat 在同一数据库内保存通讯录、会话、消息、草稿、发送上传任务及同步状态。服务端独立保存权威资料，两端不共享数据库文件；网络契约仍以服务端 `.proto` 为唯一来源。

| 决策 | 实施方式 |
| --- | --- |
| 加密和连接 | 固定 SQLCipher GRDB revision `a285e4ca87ec6b3584c97b0ec25fc61fec02de60`，`DatabaseQueue` |
| 隔离与所有权 | 环境＋账号目录，账号协调器复用实例并最终关闭；业务模块借用 |
| 表命名 | 单数 `snake_case`，名称说明业务对象与数据粒度 |
| 数据映射 | GRDB Record、Columns、类型化查询；不把网络 DTO 编码为业务 JSON |
| 内容 | 消息主表＋文本／链接／系统／未知内容表，媒体使用有序共享附件引用 |
| 集合 | 按位置保存子记录，保留顺序、重复值和有意义的 nil／空集合区别 |
| 原子性 | ChatStore 统一协调 Repository，检查点与业务批次同时提交 |
| 未上线处理 | 合并五段开发迁移为新基线；不自动擦除、换钥或重建旧库 |
| 平台 | Swift 6.3；基础包与聊天包最低 iOS 15／macOS 12，无 UIKit 依赖 |

阅读顺序：[架构](architecture.md) → [字段字典](schema.md) → [生命周期](lifecycle-and-migration.md) → [验证](validation.md)。[同步契约](sync-contract.md)保留长期目标，其未实施命令、回执明细和容量设计不应被视为当前网络接口；实际接口见[服务端协议](../../AzureFishServer/Documentation/protobuf-contract.md)。安全与密钥要求见[安全设计](../Security/README.md)。

2026-09-30：借鉴 Nirvana 的类型化 Record、分类型消息内容和专用状态更新；不复制物理表名关联、媒体独占模型、`.replace` 父记录写入或普通 SQLite 初始化。Nirvana 仅作只读源码参考，本次没有修改或运行其测试。

未来业务增加自身领域表、Repository、资源引用查询和有序迁移。收藏、红包、群回执成员明细及百万消息性能尚未实施或验证，不预建空表，也不把其他业务塞入聊天 `meta`。

2026-10-06：在现有基线后追加 `chat-media-import-v1` 导入日志迁移；不替换基线或重建已有库。导入事务与共享资源补偿见[生命周期](lifecycle-and-migration.md#媒体导入补偿)，本次验证见[修复记录](../Engineering/2026-10-06-staged-repairs.md)。

## 2026-10-11 朋友圈扩展

朋友圈新增 `moments-v1` 迁移，在现有账号主库保存动态投影、草稿、待确认操作、媒体引用及持久化回收队列；不另建明文库，不改写旧迁移。详见[朋友圈存储及恢复](../Design/Moments/README.md)。

### 朋友圈视频补充

视频草稿在既有 moments_items 加密载荷中追加可选字段，旧载荷缺失视频字段时解码为 nil。视频源及输出均有引用；重新导出释放旧输出，源文件保留供再次裁剪。源视频、导出视频、封面与动态视频资源均登记 moments_resources；沿用既有表，不改写迁移。

## 短视频接入

Pixabay 原生短视频新增独立内容与互动接口，并复用账号加密媒体存储及退出停止屏障。配置、协议、迁移和生命周期见[短视频实现说明](../ShortVideo/README.md)。该模块不改变本文的真实账号上线及安全验收门槛。
