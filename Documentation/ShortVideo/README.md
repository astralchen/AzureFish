# 原生短视频

状态：客户端、服务端与协议已接入工作区；本次验证结果见文末。现有服务端仍仅用于隔离的虚构账号测试，本功能不改变真实账号上线边界。

## 体验与数据来源

主标签新增“短视频”（聊天、联系人、短视频、发现、我），直接打开原生竖向分页列表并保留系统标签栏。发现页保留快捷入口，推入全屏页面时隐藏标签栏并保留返回入口。标签使用稳定 tag，切换语言不会重建导航栈。素材来自 Pixabay；作者、标签和来源链接与 AzureFish 内的点赞、评论分开呈现。默认静音、单视频循环播放，支持暂停、静音、拖动进度、一级评论、删除自己的评论和系统分享来源页。首版没有上传、推荐算法、关注、嵌套回复或离线写入队列。

UI／UX 参考抖音的沉浸式短视频：纵向互动按钮位于尾缘，作者和标签位于底部，轻触画面暂停／播放、双击点赞，进度条贴近底部。视频保持比例。切页、离开、退后台或音频中断会停止播放器；评论与分享呈现期间暂停并保留当前帧，关闭后按用户原来的暂停选择恢复。语言和尺寸变化不重建业务运行时。视频浮层文字随动态字体放大并限制最大字号，避免覆盖全部画面；完整语义保留在 VoiceOver 标签，评论正文支持完整动态字体。发送采用与 Chat 相近的箭头按钮。2026-10-17 的 UI 调整将静音移至顶部、分享缩短为单一动作名称；顶部使用轻量热门标题，独立 Tab 保留系统外观，iPhone 使用白色选中色，iPad 顶部标签沿用系统着色。计数说明移至信息菜单，来源链接保持可见。评论使用独立 QuickLayout Cell，按默认头像、昵称、正文和时间分层，通过菜单删除自己的评论。输入框有四语言占位提示，空内容禁止发送。本次浏览保留播放位置和评论草稿，退出账号清除内存状态。

## 客户端架构

模块按 Chat 的 Controllers／Models／ViewModels／Views／Support 分层，详见 [模块 README](../../AzureFish/Features/ShortVideo/README.md)。业务模型管理分页、草稿与互动；控制器负责单播放器和系统导航；QuickLayoutView 与 ListKit 负责展示。评论输入区复用 Chat 键盘遮挡协调器，窗口变化通过内容 inset 保留阅读位置。

## 配置与上游访问

服务端读取 `AZUREFISH_PIXABAY_API_KEY` 环境变量。项目所有者已明确授权将本次 Pixabay 开发 Key 纳入服务端 `.env.development` 的版本控制；该特例不适用于其他凭据或加密密钥。Key 不进入 iOS 包、Protobuf 或应用日志，不在验证记录中重复展示。

现有启动脚本切换至服务端目录，Vapor 自动加载配置，优先级为进程环境变量 > `.env.development` > `.env`。启动后修改配置需要重启服务才能生效；不要为更换内容源 Key 重建数据库或存储密钥。缺失配置时列表返回 `SHORT_VIDEO_SOURCE_UNCONFIGURED`，客户端显示“视频来源尚未配置，请稍后再试”。

固定请求热门、安全搜索开启、每页 20 条。筛选 1～60 秒、所选文件不超过 50 MiB 的视频，优先 small，其次 tiny、medium。查询上限 25 页，与上游单查询最多 500 条一致；过滤后可出现空页，客户端保留继续加载入口。首版不预下载下一条视频。

相同页请求在服务端合并并缓存 24 小时，缓存经过现有服务端密钥认证加密。上游 429 后暂停请求至少 60 秒；不主动批量抓取。播放地址及封面只接受 `https://cdn.pixabay.com`，来源地址只接受 Pixabay HTTPS 主站。详见 [官方 API 文档](https://pixabay.com/api/docs/)。

## 网络契约

权威定义位于服务端 `Protos/azurefish.proto`；客户端只同步副本并由 SwiftProtobufPlugin 构建生成。以下接口均为已认证的 POST，正文与响应使用 Protobuf：

| 路径 | 请求 → 响应 |
| --- | --- |
| `/v1/short-videos/list` | `ShortVideoListRequest` → `ShortVideoListResponse` |
| `/v1/short-videos/get` | `ShortVideoIdentity` → `ShortVideo` |
| `/v1/short-videos/like` | `ShortVideoLikeRequest` → `ShortVideo` |
| `/v1/short-videos/comments/list` | `ShortVideoCommentsRequest` → `ShortVideoCommentsResponse` |
| `/v1/short-videos/comments/create` | `ShortVideoCommentRequest` → `ShortVideo` |
| `/v1/short-videos/comments/delete` | `ShortVideoDeleteCommentRequest` → `ShortVideo` |

素材身份为 `pixabay:<正整数>`。游标绑定账号、用途与服务端 epoch；评论每页 20 条，按服务端序号倒序。列表、详情和写响应中的评论数均经过双向拉黑和账号删除状态过滤；点赞数为 AzureFish 全局点赞数。

点赞写入目标状态，评论创建带稳定 comment_id 与 operation_id。重试保留原身份和正文；冲突返回 `OPERATION_CONFLICT`。评论限 500 字符，每个视频最多登记 2000 个评论身份（含删除墓碑），避免过滤和计数无界增长。删除仅允许评论作者，墓碑清空正文但保留摘要，旧请求不能复活内容。

其他稳定错误：`SHORT_VIDEO_SOURCE_FAILED`、`SHORT_VIDEO_SOURCE_LIMITED`、`SHORT_VIDEO_UNAVAILABLE`、`SHORT_VIDEO_OWNER_REQUIRED`、`SHORT_VIDEO_INTERACTION_LIMIT`。客户端提供四语言文案，第三方作者与素材标签保留原文。

## 存储与生命周期

服务端迁移新增 `short_video_cache`、`short_video_likes`、`short_video_comments`。素材和评论正文使用认证加密载荷；账号、素材身份和排序序号作为索引。账号删除清理其点赞、评论及本模块幂等记录。迁移保留已有聊天、朋友圈及账号数据。

客户端复用账号的 EncryptedMediaStore 和临时导入预留：下载使用 ephemeral URLSession，禁用 URLCache 和 Cookie 存储，并校验 HTTPS、重定向目标与字节上限。视频最多 50 MiB、封面最多 4 MiB，完整数据先在有界内存中接收，再计算摘要并分块加密。播放只读取受文件保护、排除备份的短期明文租约。

滑动过程中暂停并冻结当前就绪帧，回弹到同页复用播放器；真正切页时先按旧身份保存播放位置、断开播放器，再归还租约和清理加密临时资源。账号停止屏障等待在途下载及资源清理后，才关闭共享存储。崩溃遗留的明文由 EncryptedMediaStore 启动清理，加密导入预留沿用 MomentsStore 恢复。首版不保留离线观看缓存。

## 本地验证入口

Debug 启动参数 `-short-video-demo`（独立页面）和 `-short-video-tab-demo`（五标签容器） 使用包内视频、内存互动替身和独立随机密钥账号存储，播放和互动不请求 Pixabay，也不访问真实账号（打开来源链接或系统分享预览仍可能联网）。测试入口不会进入 Release 正常流程。

新增验证涵盖服务端映射、缓存、缺失 Key、分页、点赞幂等、评论权限、拉黑和删除清理；客户端协议错误映射、请求身份、播放资格以及媒体租约生命周期；UI 样例覆盖分页播放、点赞、评论及发现入口。

## 验证记录（2026-10-17）

| 验证项 | 状态与证据 |
| --- | --- |
| 服务端 `swift test -j 4` | 通过：76 项测试、24 个 suite；包含 5 项短视频测试。显式 opt-in 的真实 socket 测试跳过。日志 `/tmp/azurefish-short-server.log` |
| AzureFishAPI 短视频协议测试 | 通过：2 项；缺失内容源 Key 的稳定错误、评论重试身份。日志 `/tmp/azurefish-short-api-tests.log` |
| 协议与本地化静态检查 | 通过：服务端／客户端 proto 字节一致，两份生成清单 SHA-256 一致；26 个 shortVideo 文案键均含简中、繁中、英文、阿拉伯语 |
| 最终客户端构建、单元／组件测试 | 通过：iOS 15 deployment target、iOS 26.5 Simulator SDK；7 项测试（ShortVideo 5、ChatStartup 2），覆盖租约释放、账号取消、重试身份、触摸穿透及五 Tab 状态 |
| iPad UI 回归 | 通过：独立 Tab、播放／分页／评论草稿；最终字号与发送按钮调整后的多语言／旋转和互动 2 项专项通过。末次评论弹层 RTL／LTR 位置断言通过 |
| iPhone UI 回归 | 通过：5 个场景分轮验证（独立 Tab、发现入口、四语言／主题／大字体／旋转、播放互动、RTL／LTR 弹层位置）。字号与发送按钮调整后 2 项专项通过，末次方向修正后位置断言通过 |
| 人工截图检查 | iPhone／iPad 的独立 Tab、原比例黑色留边、状态栏与互动布局已检查；最大辅助字体的视频浮层和评论输入区已检查；iPhone／iPad RTL 弹层方向截图已核对 |
| 真实 Pixabay 连通性、真实视频下载和播放性能 | 未执行：尚未配置 API Key；本地包内视频不能替代上游联调 |
| iOS 15～25、iOS 27.1 Duo、真机 | 未执行：当前仅安装 iOS 26.5 模拟器 |
| VoiceOver 实际朗读、降低透明度／增强对比度人工验收 | 未执行；已提供语义标签、动态字体和相应外观适配，静态实现不代替运行验收 |

固定数据测试使用本地视频与虚构用户。真实服务联调需配置 Key 后补测，包括资源失效、下载速度、首帧时延、内存峰值及上游 429 行为。本次没有生产部署。

本次客户端结果分轮记录：完整 iPhone 回归与 7 项单元／组件测试见 `/tmp/AzureFish-ShortVideo-Visual-Final-iPhone.xcresult`；iPad Tab／播放回归见 `/tmp/AzureFish-ShortVideo-Visual-Final-iPad.xcresult`；字号及输入区修正见 `/tmp/AzureFish-ShortVideo-Accessibility-iPhone.xcresult` 与 `/tmp/AzureFish-ShortVideo-Accessibility-iPad.xcresult`；最终方向修正见 `/tmp/AzureFish-ShortVideo-RTL-iPhone.xcresult` 与 `/tmp/AzureFish-ShortVideo-RTL-iPad.xcresult`。界面修正后只复测受影响场景，以上结果不代表全仓库客户端测试通过。

### 截图

以下为 iOS 26.5 模拟器中的本地固定样例，使用包内视频和虚构元数据，不代表真实 Pixabay 联调结果。

- [iPhone 独立短视频 Tab](Validation/iphone-video-tab.png)
- [iPad 系统浮动 Tab 与短视频](Validation/ipad-video-tab.png)
- [iPad 最大辅助字体的视频浮层](Validation/ipad-large-text.png)
- [iPad 最大辅助字体的评论草稿](Validation/ipad-large-comment.png)
- [iPhone 最大辅助字体的视频浮层](Validation/iphone-large-text.png)
- [iPhone 最大辅助字体的评论草稿](Validation/iphone-large-comment.png)
- [iPhone 阿拉伯语评论布局](Validation/iphone-rtl-comments.png)
- [iPad 阿拉伯语评论布局](Validation/ipad-rtl-comments.png)

## UI／UX 审查调整（2026-10-17）

本轮依据主屏、互动栏及评论面板的审查结果调整，保留独立视频 Tab 与 Chat 式代码组织，不扩展关注、上传、音乐或推荐算法。顶部改为“热门”、静音和更多菜单；发现路径保留返回按钮。右侧仅保留点赞、评论、分享，数量按当前 locale 紧凑显示，无障碍仍朗读完整数量。作者、标签、Pixabay 来源链接位于底部，计数范围与分享说明移入信息菜单。原生系统 Tab 与分享面板继续保留，不能称为抖音逐像素复刻。

评论拆出 `ShortVideoCommentCell`，采用默认头像、昵称、正文和时间的层级，不再将昵称与正文拼在同一标签。自己的评论通过省略号菜单或长按菜单请求删除，保留确认与 VoiceOver 删除操作。评论标题显示 AzureFish 计数；输入区显示占位提示，空白草稿禁用发送，发送中显示忙碌状态。新增删除 UI 回归发现旧确认框引用缺失的 `common.cancel`，已改为现有四语言 `account.design.cancel`。

播放改为拖动期间暂停并保留就绪帧；停在同页时恢复同一个播放器，切页时按旧素材身份保存位置后释放资源，再加载新页。进度条继续保留 44 pt 触摸高度，并支持 VoiceOver 的 valueChanged 调整。完整下载后播放、不预取下一条及账号加密存储规则保持不变；真实网络首帧和连续刷视频性能仍未验证。

主屏按钮的实际 `UIControl` 尺寸已修正：顶部动作至少 44×44 pt，互动栏 52×58 pt，来源按钮固定 44 pt 高度。只扩大 QuickLayout 外层容器并不能扩大按钮命中范围；来源按钮也不能仅声明最小高度，否则会占用剩余竖向空间并拦截翻页。UI 回归已加入按钮尺寸与来源高度断言。辅助字体下隐藏分享按钮的可见文字，保留完整无障碍名称，避免英文标签裁切。iPhone 视频 Tab 选中项使用白色；iPad 顶部系统标签栏保留系统强调色。

### 本轮验证

| 验证项 | 结果 |
| --- | --- |
| 客户端 `build-for-testing` | 通过；最后构建日志 `build_sim_2026-10-17T13-27-38-956Z_pid46033_63c37f4b.log`（宽窗口顶部避让修正），iOS 15 最低部署版本未提高 |
| iPhone 17 Pro／iOS 26.5 | 通过：5 项 ShortVideo 单元／组件测试、3 项 UI 测试；涵盖旧加载拒绝、账号停止、重试身份、触摸穿透、Tab 状态、播放分页、评论发送／删除／草稿、系统分享、四语言、深浅色、大字体及旋转 |
| iPad Pro 13／iOS 26.5 | 通过：3 项 UI 测试，覆盖 Tab、完整互动流程、多语言与旋转；使用窗口模式执行 |
| 发现入口、RTL／LTR 位置断言 | 本轮较早完整 UI 回归通过；最后一轮按钮尺寸修正未改变相关导航与方向逻辑 |
| 本地化／静态检查 | 通过：35 个 `shortVideo` 文案键均含四语言；模块全部字面量本地化键存在；`git diff --check` 通过 |
| 服务端、协议包测试 | 本轮未重跑：仅调整客户端体验与 UI 回归，协议和服务端无新增修改；上节保留实施阶段结果 |
| 真实 Pixabay／性能、旧系统、Duo、真机、VoiceOver 实际朗读、辅助显示人工验收 | 未执行；范围与上节限制相同，模拟器固定视频不代表真实网络刷视频性能 |

最终结果：`/tmp/AzureFish-ShortVideo-Refinement-Delivery-iPhone.xcresult`（8 项通过）与 `/tmp/AzureFish-ShortVideo-Refinement-Delivery-iPad.xcresult`（3 项通过）。较早发现入口和方向检查见 `/tmp/AzureFish-ShortVideo-Refinement-Final-iPhone.xcresult` 与 `/tmp/AzureFish-ShortVideo-Refinement-Final-iPad.xcresult`。首次发现的删除取消文案缺失、来源按钮纵向扩张均已修复并通过最终互动回归；iPad 系统分享等待调整为 20 秒，仍断言真实系统面板出现。

XCTest 在 iPad 窗口模式的应用截图出现偏移裁切，截图附件改为 `XCUIScreen.main.screenshot()`，保留完整屏幕与窗口边缘；此变更不修改应用行为。

- [本轮 iPhone 独立视频 Tab](Validation/refinement-iphone-tab.png)
- [本轮 iPhone 评论与草稿](Validation/refinement-iphone-comments.png)
- [本轮 iPhone 最大辅助字体](Validation/refinement-iphone-large-text.png)
- [本轮 iPhone 阿拉伯语评论](Validation/refinement-iphone-rtl-comments.png)

完整屏幕截图发现宽窗口隐藏导航栏后，返回按钮会与系统窗口按钮重叠。顶部控制区在 regular 宽度下保留至少 44 pt 的首行空间，并扣除已有顶部安全区；此调整仅影响浮层顶部，不增加视频画布和评论区域的整页边距，也不按设备型号分支。

窗口避让修正后再次通过 3 项 iPad UI 测试：独立 Tab、发现页返回、多语言／大字体／旋转；结果为 `/tmp/AzureFish-ShortVideo-Refinement-Window-iPad.xcresult`。已人工检查完整屏幕截图，返回按钮、静音与更多按钮不再与系统窗口控件重叠，互动栏完整显示。此轮仅调整 regular 宽度顶部间距，iPhone compact 布局未改变。

- [本轮 iPad 独立视频 Tab](Validation/refinement-ipad-tab.png)
- [本轮 iPad 大字体与窗口避让](Validation/refinement-ipad-large-text.png)
- [本轮 iPad 评论草稿](Validation/refinement-ipad-comments.png)
- [本轮 iPad 阿拉伯语主屏](Validation/refinement-ipad-rtl.png)

## 提交前全量改动审查（2026-10-17）

审查范围包括工作区全部新增与修改文件：独立 Tab 与发现入口、播放器与评论状态、账号停止屏障、加密媒体导入和租约、Pixabay 适配、数据库迁移、HTTP／Protobuf 契约、四语言资源、测试及文档。

本轮发现并修复：

- 详情旧快照可能晚于评论写响应返回并覆盖计数；为详情刷新增加版本校验，外部权威更新使旧读取失效。
- 评论删除时在途列表读取可能恢复已删条目；写入前取消并作废读取，写入期间阻止重新读取。评论面板刷新同时获取当前互动快照，使重新前台后的标题计数更新。
- 详情和评论列表原先没有读取限流；现与列表共用每账号每分钟 120 次限额，在数据库扫描前检查。
- 全量服务端测试发现并发缓存读取会以过期快照启动重复请求；把缓存读取、上游访问和缓存写入全部纳入同一个合并任务。

服务端 `swift test -j 4` 通过（77 项、24 个 suite；真实 socket opt-in 测试仍跳过），日志 `/tmp/azurefish-review-server.log`。AzureFishAPI 短视频 2 项协议测试通过，日志 `/tmp/azurefish-review-api.log`。客户端 `build-for-testing` 通过，日志 `build_sim_2026-10-17T13-52-02-953Z_pid46033_e010de39.log`；6 项 ShortVideo 和 2 项 ChatStartup 单元／组件测试通过，其中新增受控延迟读取回归。

客户端首轮结果 `/tmp/AzureFish-ShortVideo-Review-iPhone.xcresult` 的整体状态为失败：8 项单元／组件通过后，UI Runner 因 Accessibility 初始化超时未开始执行，不能将该 bundle 记为全部通过。

重启本任务模拟器后，单独重跑 `testPlaybackPagingAndCommentDraft` 通过（1 项、0 失败），覆盖播放、分页、点赞、评论发送／删除、草稿及系统分享；结果为 `/tmp/AzureFish-ShortVideo-Review-UI-Retry.xcresult`。本轮未修改布局，iPhone／iPad 多语言与窗口截图沿用上节记录。`git diff --cached --check` 通过，复审未发现剩余的阻塞提交问题。

服务端／客户端 proto 字节一致，两份清单哈希与源文件一致；使用 protoc 35.1 与现有 SwiftProtobuf 生成器重新生成至临时目录，产物与服务端提交文件逐字节一致。35 个短视频文案键均含四语言，全部字面量本地化引用及文档链接检查通过；依赖锁文件无修改。真实 Pixabay、播放性能、旧系统、Duo、真机及实际 VoiceOver 验收仍未执行。

## 开发 Key 配置与真实源联调（2026-10-17）

本轮启用现有 Pixabay 内容源，不修改客户端业务实现、公共接口、协议、数据库定义或依赖。服务端新增受版本控制的 `.env.development`，仅放行服务端根目录的这个文件；其他 `.env.*`、`.local` 与存储密钥继续忽略。提交实际开发 Key 是项目所有者明确授权的特例。启动使用原有 `Scripts/run-local.sh`，复用原数据库和存储密钥；已有待执行迁移由正常启动流程处理，没有删除或重建数据。本轮未执行生产部署。

### 验证结果

| 验证项 | 本轮结果 |
| --- | --- |
| 配置、文档与静态检查 | 通过：开发配置可纳入 Git，其他环境与密钥文件仍忽略；实际 Key 仅出现在该配置中，未出现在业务源文件和本轮服务端／联调日志；相对链接与 `git diff --check` 通过 |
| 服务端短视频回归 | 通过：`swift test -j 4 --filter ShortVideoTests`，7 项测试；新增参数化用例覆盖上游 HTTP 错误、无效 JSON、网络超时，均返回稳定错误且不泄露 Key；原有缓存合并／过期、缺失 Key、429 和互动权限测试通过 |
| 客户端测试构建 | 通过：`build-for-testing`，iOS 26.5 Simulator SDK；未提高最低部署版本 |
| 真实列表、缓存与分页 | 通过：虚构账号的 Protobuf 请求返回两页，每页 20 条视频；首个冷缓存列表请求 1.395 秒，重复请求 0.132 秒；相同页重复读取时加密缓存载荷不变 |
| 真实互动 HTTP 链路 | 通过：点赞、取消点赞、创建评论、读取评论、删除测试评论、退出会话均返回预期结果；互动仅写入本机虚构账号服务 |
| 原生封面请求 | 通过：macOS 原生 ephemeral URLSession 下载并解码同一真实素材封面，HTTP 200，88,246 字节、960×540，约 3.95 秒；此项是下载与解码检查，不代替 iOS 加载中封面的视觉验收 |
| iPhone 真实源 UI | 通过：独立 iPhone 17 Pro／iOS 26.5 模拟器，`ShortVideoLiveUITests/testLivePlaybackPagingAndInteractions` 1 项、0 失败、0 跳过；正常账号入口及短视频 Tab，真实下载和播放进度推进、暂停进度保持、静音切换、点赞恢复、评论发送／删除、翻页后播放全部通过 |
| 人工截图检查 | 已检查真实视频画面、Pixabay 来源及正常五标签入口；截图见下方。不代表本轮重新完成全部布局和无障碍验收 |
| Python 下载探针 | 失败：同一 CDN 封面与视频返回 HTTP 403／Cloudflare 1010；原生封面请求与 iOS 实际播放成功，因此未据此修改 Key、放宽 TLS 或改写请求身份 |
| 性能验收 | 未执行完整基准：三轮 UI 自动化观测到进入视频页至进度条可用约 8.53、12.55、25.17 秒，含 XCTest 等待与观测开销，不是精确首帧计时。加载延迟波动仍需专项评估 |
| 其他平台与回归 | 本轮未执行 iPad、iOS 15～25、Duo、真机、四语言／主题全量 UI、VoiceOver、内存峰值或全仓库测试；此前记录不作为本轮结果 |

真实 UI 用例仅在测试 Runner 环境设置 `AZUREFISH_PIXABAY_UI_LIVE=1` 时运行，普通运行默认跳过。测试使用已有虚构会话或注册虚构账号，成功路径恢复点赞状态并删除其测试评论；运行中断可能留下虚构测试数据。已有模拟器因旧账号数据格式不兼容未用于最终验收，原数据保留，最终使用独立模拟器。测试脚本已处理 Password AutoFill 输入、单击等待双击手势失败及评论面板键盘焦点等待；未为测试更改产品行为。

早期失败结果不计入最终通过：一次旧账号恢复错误、一次自动化两次密码输入不一致、一次暂停断言过早、一次评论键盘尚无焦点。新模拟器首次测试的工具调用还曾超时，已核对后台最终结果，没有将工具超时直接计为构建失败或测试通过。

证据：服务端日志 `/tmp/azurefish-pixabay-server-tests.log`；真实 API 记录 `/tmp/azurefish-pixabay-live-api.log` 与 `/tmp/azurefish-pixabay-live-api-retry.log`；原生封面记录 `/tmp/azurefish-pixabay-native.log`。最终客户端构建日志为 `build_sim_2026-10-17T14-51-11-944Z_pid59423_9adae838.log`，最终 UI 结果为 `test_sim_2026-10-17T14-52-36-115Z_pid59423_2d3e0ad6.xcresult`，位于本机 `~/Library/Developer/XcodeBuildMCP/workspaces/AzureFish-f786ca84ece4/` 下对应 `logs/` 与 `result-bundles/` 目录。

- [真实 Pixabay 视频与正常短视频 Tab](Validation/pixabay-live-playback.png)
