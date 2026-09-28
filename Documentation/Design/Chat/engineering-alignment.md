# 聊天设计与工程对照

2026-09-27 按用户要求更新：**聊天内容和输入区以现有 `Features/Chat` 为视觉依据，导航栏保留当前 Figma 设计**。新增真实接入的 `Features/Messaging` 不是本次视觉基准。设计导出保存在 [Previews](Previews/index.html)，可离线查看；可编辑源仍在 Figma。

## 对照规则

| 内容 | 工程依据 | 设计表现 |
| --- | --- | --- |
| 文本气泡 | [TextBubbleView](../../../AzureFish/Features/Chat/Views/Chat/TextBubbleView.swift) | 横向 12、纵向 8 pt 内边距；18 pt 圆角、方向角 5 pt；发送蓝底白字，接收使用语义次级填充 |
| 消息排布 | [TextBubbleCell](../../../AzureFish/Features/Chat/Views/Chat/TextBubbleCell.swift) | 页面左右 12 pt；单元上下各 2 pt；气泡最大宽度 `min(420, max(140, width × 0.75))`；回执间距 3 pt |
| 输入栏 | [ComposerView+Layout](../../../AzureFish/Features/Chat/Views/Composer/ComposerView+Layout.swift) | 外侧左右 16、上下 8 pt；附件入口 44 pt，与输入胶囊相隔 8 pt；输入及操作目标至少 44 pt |
| 媒体内容 | [MediaMessageView](../../../AzureFish/Features/Chat/Views/Chat/MediaMessageView.swift) | 延续原有媒体卡片、顺序和独立浏览语义；本次没有把业务上传页改成聊天气泡 |
| 语音、文件 | [AudioBubbleView](../../../AzureFish/Features/Chat/Views/Chat/AudioBubbleView.swift)、[DocumentBubbleCell](../../../AzureFish/Features/Chat/Views/Chat/DocumentBubbleCell.swift) | 沿用波形、播放和文件卡片方向；服务端转写、链接预览不因此进入本期能力 |
| 导航栏 | 现有 Figma 导航 | 保留返回、名称／头像和详情入口；通讯录及三标签不回退为演示导航 |

以上源码链接从 Chat 文档目录指向仓库根目录；Figma 的文字、Auto Layout 和颜色变量继续可编辑。设计字体沿用 SF Pro 与 Noto CJK／Arabic 替代，运行时仍使用系统字体，未宣称字体像素完全一致。

## 更新与检查

- 撤回改为居中提示；本人文本在本机确认成功后三分钟内可重新编辑，已有文字先确认替换，媒体无编辑入口。实现、九张设计图和验证结果见 [专项交接](revoke-reedit.md)。
- 会话行、新的朋友入口和 Tab 未读徽标统一红底白字。聊天 Tab 汇总所有会话的权威未读数，不受本地搜索或当前 Tab 影响；0 时隐藏，超过 99 显示“99+”。点击 Tab 不会标记消息已读。Figma 三标签组件提供未读数文字和显示开关，示例 2 + 3 = 5。
- 已更新私聊、群聊及发送状态、撤回占位、好友接受后的聊天，以及深色、繁中、阿拉伯语、窄屏、大字体、旧系统和双栏适配稿的气泡／输入区。
- 复用了原有 Appearance、Metrics 变量集合，补充接收气泡填充和气泡圆角参数。没有新增主题系统或 Code Connect 类型映射。
- 已查看私聊、群聊、深色、大字体和双栏渲染；修正颜色绑定的回退值和双栏缺少附件入口的问题。导航栏没有因本次工程对齐重画。
- 原有原型动作保留；本次没有逐条运行浏览器原型流程。PNG 为静态设计导出，不代表真实上传、消息同步、VoiceOver、动态字体或系统玻璃效果验证。
- iOS 15～25 为原生非玻璃外观，26+ 由系统呈现 Liquid Glass。设计稿只表达布局，不用静态透明色模拟系统材质保证。

## 仍需运行验收

真实应用须继续验证阅读锚点、键盘、长文本、媒体播放、窗口折叠、RTL、VoiceOver 与触控区域。当前设计更新完成不等于整体“真实聊天接入”计划完成；运行状态单独记录于 [实施记录](contacts-implementation.md)。

## 全屏列表与空状态更新（2026-09-27）

移除假会话行和空页大按钮；新增 Chat/ListState 四状态组件及七张工程 PNG。原始导航和三标签保留。布局、同步基线、四语言文案与验收边界见 [专项交接](conversation-list-empty.md)。

## 数量徽标修复（2026-09-27）

自定义 accessory 保留已计算的 22 pt 红底白字徽标尺寸，修复通讯录与聊天行被压成细条的问题；设计尺寸不变。[原因、截图与验证](unread-badge-fix.md)。

## 原版消息区接入补充

2026-09-27：iOS 26+ 真实会话改用原版聊天组件，保留真实导航；富文本、链接、发送顺序和加密草稿同步接入。以下历史结果不代替本次验证，详见[接入记录](original-ui-restoration.md)。
