# 撤回提示与三分钟重新编辑

2026-09-27：实现已进入真实聊天时间线。服务端撤回接口与清除正文的行为保持不变；本次没有修改或重启现有 8080 服务。

## 用户行为

- 撤回显示居中的次级文字，移除气泡、发送者行和回执。本人显示“你撤回了一条消息”；私聊对方显示“对方撤回了一条消息”；群聊使用发送者昵称，缺失时使用本地化的“群成员”。
- 仅本机发起撤回的本人文本提供“重新编辑”。从本机首次确认成功开始计时，三分钟到期隐藏入口；重启或重复响应不续期。他人、媒体及其他设备发起的撤回不提供原文恢复。
- 点击填入当前会话输入栏、唤起键盘并把光标放到末尾，不自动发送。有不同文字时先确认替换；取消不改变草稿，替换仅修改文字，附件身份和顺序保留。
- 确认时再次检查身份、会话、发送权限、草稿和期限。已经恢复成普通草稿的内容不随恢复入口到期被清除。发送使用新的消息身份，原撤回占位不消失。
- 撤回结果未知时先同步确认，不把网络错误当作确定失败。同步已确认成功后，迟到的 HTTP 错误不能覆盖成功。

## 本机存储与生命周期

`AzureFishChat` 在原 SQLCipher 账号库追加 `chat-v2-revoke-recovery` 迁移，不重建数据库或密钥。恢复记录与消息正文、FTS 搜索分开保存，不进入日志。

网络调用前保存原 operation ID 和本人原文。待确认副本最多保留三分钟；在此期限内，HTTP、历史或事件首次确认撤回时，与消息更新同事务转为可编辑并固定新的三分钟截止时间。超过待确认期限后到达的成功仍撤回消息，但不恢复编辑副本。

失败、到期、本机删除和清空会话均清除恢复正文；仅保留最小操作身份与状态，防止旧重试重建副本。启动、读取、同步及前台恢复检查期限，页面计时任务在截止时移除入口。清除账号数据库时记录随库清除；普通离线和退出不改变已持久化的截止时间。

恢复副本写入失败不阻止服务端撤回。成功但副本不可用时提示“消息已撤回，但无法重新编辑”。错误密钥沿用账号库的拒绝访问策略，没有明文回退。

## 设计交付

四语言文案见 [reedit-copy.md](reedit-copy.md)，与应用 String Catalog 同步。

复用系统语义颜色、字体和 QuickLayout 布局。常规宽度提示与动作居中并排；长昵称、大字体或窄空间改为上下排列。编辑目标至少 44×44 pt，Cell 复用清除旧回调。Figma 保留既有导航栏，替换草稿使用覆盖在聊天页面上的确认弹窗示意。

| 状态 | 工程内 PNG | 可编辑 Figma |
| --- | --- | --- |
| 本人文本撤回 | [图片](Previews/revoked-message.png) | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2555) |
| 对方撤回 | [图片](Previews/revoked-other.png) | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=116-1961) |
| 媒体撤回 | [图片](Previews/revoked-media.png) | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=116-1994) |
| 超过三分钟 | [图片](Previews/revoked-expired.png) | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=116-2027) |
| 已恢复到输入栏 | [图片](Previews/reedit-draft.png) | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=116-2060) |
| 输入栏已有文字 | [图片](Previews/reedit-existing.png) | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=116-2099) |
| 替换确认 | [图片](Previews/reedit-confirm.png) | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=116-2138) |
| 群成员撤回 | [图片](Previews/revoked-group.png) | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=119-1992) |
| 深色 | [图片](Previews/revoked-dark.png) | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=119-2021) |

原型贯通“重新编辑 → 输入栏”，以及“已有草稿 → 确认／取消”。图中预填输入是静态样例，不模拟真实系统键盘或三分钟计时。编辑前后的消息身份变化通过真实 HTTP 联调验证。

## 验证记录

- 存储：六项撤回专项测试通过，覆盖期限边界、重开不续期、旧结果、草稿冲突和附件保留、删除清理、他人／媒体排除及同步先于响应；原有三项存储测试通过。
- Simulator：两项撤回提示组件测试通过，覆盖按钮动作、复用回调清理、320／390／700 pt、长文字、大字号和 RTL 布局。
- HTTP 独立联调：通过。在随机回环端口验证撤回、原文恢复、附件身份保留、新消息身份及原撤回占位；关闭本机数据库后仍能完成服务端撤回，且不提供重新编辑。历史接口按稳定消息身份核对，不依赖数组顺序。
- Figma：已渲染检查本人、草稿、确认、深色及群成员状态；编辑按钮为 68×44 pt。逐条浏览器点击原型未执行。
- 四语言已进入 String Catalog；完整 VoiceOver 导航、真实系统大字体切换、旧版 iOS、真机及 Duo 未执行，不用静态设计或组件布局测试替代。

机器记录见 [reedit-validation.json](reedit-validation.json)。最终 Simulator 编译与专项测试、协议副本检查、33 张 PNG 完整性、12 条四语言文案、文档链接和 `git diff --check` 均通过。完整 App 回归此前的历史锚点失败仍按原实施记录保留，本次没有将其标记为修复。
