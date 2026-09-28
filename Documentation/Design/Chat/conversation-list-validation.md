# 全屏会话列表验证记录

日期：2026-09-27。Xcode 26.5，Swift 6，iPhone 17 Pro／iOS 26.5 Simulator。

| 验证类别 | 结果 | 证据与边界 |
| --- | --- | --- |
| 同步与加密存储单元测试 | 通过 | `ChatSyncStateTests`、`ChatStoreTests`、`ChatReeditTests`，10 项；初始／本地变更不确认同步，失败状态保留，既有加密存储与撤回回归 |
| Simulator 状态与布局测试 | 通过 | `ChatListStateTests` 4 项，加撤回布局 2 项；全屏 frame、无重复 inset、初次同步／空／搜索／失败状态、大字体／RTL、44 pt 重试、真实系统容器与首末行位置 |
| 键盘遮挡 | 通过（组件） | 通过系统键盘通知注入 300 pt 遮挡，检查可见区域和隐藏后 inset 恢复；没有把通知注入描述为真实键盘输入自动化 |
| 深浅色运行截图 | 通过（内容布局） | [浅色](Validation/ConversationList/chat-list-light.png)、[深色](Validation/ConversationList/chat-list-dark.png)：UIKit 组件宿主窗口截图，只使用空状态固定样例；不连接服务，不作为登录／同步全流程证明。系统玻璃的最终屏幕合成效果不由 drawHierarchy 截图认证 |
| Figma 与工程 PNG | 通过 | 四状态可编辑组件、七张 PNG、浅深色与 320 pt iPad 列表栏；检查字体、文字换行、布局和重试连线 |
| 四语言 | 通过（资源检查） | 新增 10 条文案包含 zh-Hans／zh-Hant／en／ar；RTL 大字组件已测，四语言完整页面人工操作未执行 |
| 双架构 Simulator 编译 | 通过 | `generic/platform=iOS Simulator`，未增加最低系统版本 |
| iOS 15～25、iPad 系统容器、真机、Duo | 未执行 | 本机本轮使用 iPhone iOS 26.5；窄栏组件与设计稿不能代替这些系统运行结果 |
| VoiceOver、降低透明度人工操作 | 未执行 | 静态检查语义标签／字体／颜色，未声称完整无障碍运行验收 |
| 真实服务与账号切换端到端 | 未执行 | 没有启动、修改或重启 8080；账号代次保护通过代码检查，尚无本次完整双账号运行证据 |
| 文档链接、PNG 摘要、`git diff --check` | 通过 | 40 张设计 PNG 尺寸与 SHA-256 一致，Markdown／画廊本地链接有效；[静态结果](conversation-list-static-validation.json) |

日志（本机临时目录）：`/tmp/azurefish-list-core.log`、`/tmp/azurefish-list-ui-final.log`、`/tmp/azurefish-list-capture-final.log`、`/tmp/azurefish-list-build-final.log`。

首轮大字体测试发现重试按钮实际高度 33 pt，修正为可伸缩的双轴布局后通过。截图捕获增加系统外观切换等待，避免将玻璃控件的过渡帧作为验收图。已有 `LiveConversationViewController` actor 隔离警告与 Protocol 配置文件资源警告不属于本次新增，未据此宣称全仓无警告。
