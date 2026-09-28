# 全屏会话列表与空状态

2026-09-27。代码、Figma 与工程 PNG 同步交付；下列设计图不代表系统运行截图。

## 布局与交互

`UICollectionView` 铺满控制器根视图，在 iPad 双栏中铺满列表栏。列表不再包安全区 padding，采用系统 `.automatic` content inset，保留大标题、搜索、导航栏“＋”菜单和三标签。底部仅对实际覆盖全宽底边的键盘补足遮挡高度，扣除系统已计算的底部 inset；浮动键盘不会把整页变成额外留白。

空状态是 collection backgroundView，不进入数据快照、点击回调或会话数量。提示在可见内容区居中；标题为动态 `.headline`，说明为动态 `.subheadline`／`secondaryLabel`，间距 8 pt，左右至少 24 pt。没有插画、大按钮、箭头或分隔线。极大字体或短窗口下提示可滚动；加载失败才提供最小 44×44 pt 的重试按钮。

搜索不会改变聊天 Tab 总未读数；搜索时展示匹配的置顶与普通会话，清空搜索恢复原有折叠状态。取消搜索、刷新、窗口变化不重建业务会话。下拉刷新等待共享同步完成，不立即结束动画。重试保留焦点与搜索词。

置顶折叠、草稿摘要与排序的完整规则见 [会话排序与显示](conversation-ordering.md)。有置顶会话时，列表上方提供原生展开／折叠按钮，至少 44 pt；从当前容器顶部安全区域开始布局。没有置顶或正在搜索时保持全屏列表。

## 状态来源

| 情况 | 页面行为 |
| --- | --- |
| 本地库仍在打开，或没有完整快照且正在同步 | 进度指示与“正在加载聊天…” |
| 完整快照已保存，列表为空 | “暂无聊天”及从好友发起聊天说明 |
| 有本地数据基线，搜索没有匹配项 | “未找到聊天”“试试其他名称。” |
| 无可用内容且同步失败 | “暂时无法加载聊天”、检查连接说明、重试 |
| 有完整缓存或已有会话，同步未完成 | 保留内容，导航区域显示轻量同步状态；不清空列表 |
| 本地加密库无法打开或读取失败 | 明确的本地存储错误；不以空列表代替，不创建替代空库 |

`ChatEngine.updates()` 提供独立的 `ChatSynchronizationState`（idle／syncing／synced／failed）以及既有连接观察值。初始值不是成功；本地消息变化不能清除同步失败或证明首次同步完成。`ChatRuntime.hasSnapshot` 来自既有持久化 checkpoint，只有完整快照事务会建立该基线，无新增数据库结构。旧 bool 变化流保留，初始值改为实际观察值。

读取联系人、会话与 checkpoint 后再次检查运行环境代次，退出或切账号后不发布迟到结果。会话摘要异步物化也按每次渲染代次隔离，搜索或刷新后旧结果不能覆盖新结果。

## 工程设计图与可编辑源

| 状态 | 工程图片 | Figma |
| --- | --- | --- |
| 暂无聊天 | [PNG](Previews/conversation-empty.png) | [编辑](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-1860) |
| 首次加载 | [PNG](Previews/conversation-loading.png) | [编辑](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-1889) |
| 搜索无结果 | [PNG](Previews/conversation-search-empty.png) | [编辑](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=130-2029) |
| 无缓存加载失败 | [PNG](Previews/conversation-load-failed.png) | [编辑](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=130-2075) |
| 缓存同步失败 | [PNG](Previews/conversation-sync-failed.png) | [编辑](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2003) |
| 深色空列表 | [PNG](Previews/conversation-empty-dark.png) | [编辑](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=130-2124) |
| iPad 双栏空列表 | [PNG](Previews/ipad-chat-empty.png) | [编辑](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=133-1910) |

[Chat/ListState 组件](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=129-1818)包含四个状态，复用既有颜色变量。中文沿用文件 Noto Sans SC，系统图标采用 SF Pro；App 使用系统字体。静态加载稿表达加载状态，旋转活动指示器由 UIKit 实现。失败稿的重试连线进入加载稿，不模拟真实网络。

## 四语言文案

来源为 `Localizable.xcstrings` 的 `chat.list.*`；文案表见 [空状态文案](conversation-list-copy.md)。操作不展示内部错误码、同步游标或数据库路径。

## 验证边界

本次验证结果统一记入 [验证记录](conversation-list-validation.md)。Figma 静态检查与 Simulator 组件截图单独标记；不将其作为真实服务、VoiceOver 人工操作或旧系统运行验收。既有 8080 服务不修改、不重启。
