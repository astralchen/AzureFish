# 好友通过双向聊天提醒

2026-09-28。工程与服务端共同实现；只影响新发生的接受操作，不为旧好友补历史。

## 行为与数据

接受申请的同一事务创建或复用私聊，并追加一条 `system / friendship_accepted` 消息。双方列表出现会话，分别增加一条未读，聊天 Tab 使用权威未读总数；不自动导航，不弹窗、不发声音。接受申请不会直接推进已读。

提示为居中次级文字，无头像、气泡、回执和发送状态；只提供本机删除。仅在实际可见且历史连续覆盖时推进阅读水位。阅读历史时保留位置。删除好友不删除该历史记录，重新添加并通过会生成新的系统提示。

服务端 `IMMessage.system_event` 追加字段 18，`IMConversation.latest_message` 追加字段 11。系统消息没有用户发送者、设备、客户端消息 ID 或回执，`message_uuid` 和 `server_message_id` 由服务端生成。事件保存关系 ID、关系版本和双方身份，不保存中文文案。客户端只负责本地化显示。

关系 ID＋接受版本经用途隔离摘要生成去重键，复用现有加密消息表及唯一约束。任何事务失败均回滚关系、会话、消息、事件及幂等结果。系统类型不开放发送、撤回或回执明细接口。

列表优先读取权威最新消息，并遵守本机隐藏记录；摘要不会写入历史覆盖。旧事件不覆盖较新的摘要，旧缓存字段缺失可解码。清空会话同时隐藏仅存在于摘要中的最新消息，重启和重复同步不能恢复显示。

## 文案

| 角色 | 简中 | 繁中 | English | العربية |
| --- | --- | --- | --- | --- |
| 申请人 | 对方已通过你的好友申请，可以开始聊天了。 | 對方已通過你的好友申請，可以開始聊天了。 | Your friend request was accepted. You can now chat. | تم قبول طلب صداقتك. يمكنكما الدردشة الآن. |
| 接受方 | 你已通过对方的好友申请，可以开始聊天了。 | 你已通過對方的好友申請，可以開始聊天了。 | You accepted the friend request. You can now chat. | لقد قبلت طلب الصداقة. يمكنكما الدردشة الآن. |
| 未知事件 | 系统提示 | 系統提示 | System notice | إشعار النظام |

## 可编辑设计与工程图片

| 状态 | Figma | PNG |
| --- | --- | --- |
| 申请人列表未读 | [145:2035](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=145-2035) | [图片](Previews/Friendship/requester-list.png) |
| 接受方列表未读 | [145:2100](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=145-2100) | [图片](Previews/Friendship/accepter-list.png) |
| 申请人阅读后列表 | [145:2165](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=145-2165) | [图片](Previews/Friendship/read-list.png) |
| 申请人对话提示 | [145:2230](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=145-2230) | [图片](Previews/Friendship/requester-chat.png) |
| 接受方对话提示 | [145:2259](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=145-2259) | [图片](Previews/Friendship/accepter-chat.png) |
| 接受方阅读后列表 | [148:2075](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=148-2075) | [图片](Previews/Friendship/accepter-read-list.png) |

复用已有导航、Tab 和次级提示组件。Figma 使用现有 SF Pro 图标与 Noto Sans SC 中文设计字体；应用仍使用 UIKit 动态系统字体。列表点击会话进入对应提示页，返回连接阅读后列表。原型只演示预设阅读结果，不验证真实同步或 VoiceOver。

## 验证记录

| 项目 | 本轮结果 |
| --- | --- |
| Server 回归 | 45 项实际通过，3 项显式启用的客户端 harness／大文件测试跳过；包含重复接受、重新添加、独立已读、容量限制、事务故障与重启 |
| 随机回环 HTTP | 通过；双方快照、历史、系统提示及未读，单方阅读只清除本人未读；原消息、群聊、撤回和实时断连 smoke 继续通过 |
| Chat 加密存储 | 16 项实际通过，1 项外部真实服务客户端联调测试跳过；包含摘要不形成历史覆盖、旧事件与本机隐藏、重启 |
| API | 22 项实际通过，2 项显式启用的真实服务联调跳过；新系统事件契约与 Codable 往返通过 |
| Protocol | 5 项通过；系统事件字段 18、最新消息字段 11、未知字段保留和原媒体协议往返 |
| Simulator 编译与组件回归 | iPhone 17 Pro／iOS 26.5，6 项测试通过；提示行、四语言换行、320／390／700 pt、RTL、复用、徽标和真实聊天适配 |
| Figma 与工程图片 | 6 个可编辑页面及原型连接已读回核对；导出图人工检查通过；工程预览索引共 46 张 PNG 摘要校验通过 |
| 静态检查 | 协议副本同步、更新文档本地链接、Python smoke 语法和 `git diff --check` 通过 |
| 未执行 | iOS 15～25 系统实际运行、完整 iPad 双栏交互、Duo、真机、VoiceOver 人工操作、辅助功能极限字号与降低透明度；没有 APNs／声音／生产部署 |

运行截图：[浅色](Validation/Friendship/system-notice-light.png)、[深色及 RTL 布局](Validation/Friendship/system-notice-dark-rtl.png)。这是模拟器内真实聊天控制器读取加密测试数据的截图，HTTP fixture 刻意离线，故顶部有离线／重试提示；截图不是双账号 UI 全流程联调，也不是阿拉伯语整页截图。提示居中、无气泡及回执已人工查看；兼容页面的提示 Cell 在同一模拟器内完成组件检查，不替代旧系统运行。

日志：`/tmp/azurefish-friend-server-final.log`、`/tmp/azurefish-friend-chat.log`、`/tmp/azurefish-friend-api-final.log`、`/tmp/azurefish-friend-protocol.log`、`/tmp/azurefish-friend-ios-final.log`。模拟器结果包为 `Test-AzureFish-2026.09.28_10-28-37-+0800.xcresult`；截图校验及来源见 [manifest](Validation/Friendship/manifest.json)。

现有 8080 服务未修改或重启；本次行为需要运行新的后台与客户端版本后生效。只为后续新发生的接受操作生成提示。
