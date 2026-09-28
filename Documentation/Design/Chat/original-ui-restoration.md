# 原版聊天 UI 接入记录

2026-09-27。视觉基准为首次迁入提交 `2a5b35c` 的 `Features/Chat`。本轮复用其组件和交互，不修改 Figma。导航继续使用真实会话标题、系统返回和会话详情入口。

## 已实现

- `ConversationPageFactory` 统一聊天列表、好友资料和双栏容器入口。iOS 26+ 注入 `LiveChatSession`，使用原版 `ChatViewController`、ConversationView、ComposerView、消息 Cell、附件菜单、浏览与转场；15～25 继续使用 `LiveConversationViewController`，富文本显示纯文本、链接显示 URL。
- 页面操作通过 `ChatSessionProviding` 交给真实账号的 ChatRuntime／ChatEngine；演示入口继续使用原有独立 ViewModel、样例历史和草稿，不启用真实网络。自动回复、模拟已读和正在输入不进入真实会话。
- 原版格式编辑、文本选择、混合粘贴、文件、照片／视频／GIF／Live Photo、语音预览、听写、播放和转写沿用原组件。真实权限、群成员名、发送／上传状态、失败重试、取消、撤回和三分钟富文本重新编辑由业务数据提供。新增内容提示和历史分页沿用时间线锚点策略。
- UUID 到页面身份映射在同一页面内稳定；服务端确认替换同一个待发身份。窗口、语言与主题刷新不重新创建编辑器或会话。
- `ChatTextRun` 表达有序格式片段，`linkURL` 表达原始链接。协议由服务端生成并同步；客户端仅在构建时生成类型。具体字段与兼容规则见[权威契约](../../../AzureFishServer/Documentation/im-contract.md)。
- SQLCipher 迁移增加持久发送顺序和重新编辑格式。混合内容按原版分段，在同一事务中入队并消费草稿。附件先后上传完成不会改变同一会话的发送顺序；失败的队首阻止后续超越，取消后解除阻塞。已有纯文本、附件草稿和待发记录可继续读取。

## 存储和生命周期

`AccountChatDraftStore` 将语义草稿和展示缓存写入账号 SQLCipher，将文件写入账号 AES-GCM 媒体存储。快照仅引用 `azurefish-media://UUID`，真实内容不会进入演示 JSON 草稿。草稿读、写、发送共用顺序链；发送事务完成前保留草稿，发送中退出不再追加旧快照。

播放、预览、分享和系统保存使用账号 `page-leases` 下受文件保护且排除备份的页面副本。复制任务持有页面租约，结束后释放；页面退出清理、账号停止清理、启动清理遗留目录。撤回取消该消息转写／下载、停止播放、关闭预览，删除页面与导出副本，并清理加密展示缓存和资源。缓存更新保留被替换资源的清理索引；删除／撤回会清除所有历史版本，并拒绝过期异步结果重新写入。系统已经导出的用户副本不在应用可撤回范围内。

网页预览在客户端通过无 URLCache、无 Cookie、无凭据持久化的临时会话获取；仅 HTTPS 获取元数据，HTTP 链接仍接受并显示原始 URL。HTML／图片有字节上限和超时；失败保留链接。语音转写仍使用原版客户端识别服务；失败保留可播放音频。网页预览与转写按账号加密缓存，不上传到服务端，不新增真实输入状态协议。

## 本次验证

本节仅记录本轮命令实际结果；预览图、历史记录和编译不替代运行验收。结构化结果见[验证摘要](original-ui-validation.json)，截图见[运行截图说明](Validation/OriginalUI/README.md)。

| 项目 | 状态与证据 |
| --- | --- |
| 应用最终编译 | 通过：generic iOS Simulator，x86_64／arm64；使用 iOS 26.5 SDK，覆盖最后的上传取消缓存清理修改。旧真实页面仍有一处 actor 隔离编译警告，构建成功不代表该旧路径运行验收通过。 |
| 服务端完整 Swift Testing | 通过：45 项、12 个 suite；富文本／Unicode、链接、幂等、历史、撤回清理及原有权限／媒体回归。显式开关的真实 Socket 与客户端联调另行运行。 |
| iOS 26.5 真实页面适配组件 | 通过：加密富文本及附件草稿、账号隔离、失败不消费、真实页面路由和确认后身份稳定，共 3 项。采用虚构业务数据与隔离账号，不是生产网络验收。 |
| 聊天包 Swift Testing | 通过：16 项、5 个 suite，包含持久顺序、回滚不消费草稿、旧 outbox 解码、富文本重新编辑、加密存储，以及删除消息清理多版本资源和拒绝迟到缓存结果。 |
| 隔离真实 HTTP 联调 | 通过：随机回环端口、虚构账号；真实媒体 → 富文本 → 链接顺序、群聊、幂等及撤回。`ClientChatHarnessTests` 启动服务，`IndependentChatTests` 使用真实客户端包。 |
| 原版 UI 基础回归 | 通过：混合媒体草稿重启、预览、发送后清空；首次历史到底部且连续帧稳定。截图在 `Validation/OriginalUI`。历史锚点专项也已通过：测试现在等待 `initialPresentation.isPresented`，随后仍严格检查可见消息位移 <2 pt、转写增高和末尾跟随。富文本选择菜单、加粗编辑和发送专项通过。键盘切换照片面板专项通过，切换前后输入栏底边均为 539 pt，保持原有 ≤1 pt 断言；另有两项组件测试覆盖菜单先隐藏键盘、父容器缩放、拖动上限与关闭归零。 |
| iPhone／iPad 组件复核 | 通过：两台 iOS 26.5 模拟器各 13 项、3 个 suite；真实适配、富文本、Dynamic Type 气泡、历史锚点。包含浅深色和 RTL 运行截图；不代表完整四语言或窗口动态变化验收。 |
| 旧系统、iOS 27.1 Duo、真机 | 未执行：当前仅安装 iOS 26.5 模拟器；不以 availability 编译代替运行。 |
| VoiceOver、降低透明度、增强对比度、真实麦克风／听写／Photos 写入 | 未执行人工及权限验收；对应原组件复用不代表本次已验证通过。 |

实际截图保存在 `Validation/OriginalUI/`。测试中的离线提示和历史加载失败属于刻意断网的虚构会话，不表示服务端成功同步。完整媒体类型的双账号 UI 操作、账号切换与窗口变化的验收仍需与下方命令结果逐项区分。

### 未通过与验收边界

完整 `ChatAudioTranscriptionTests` 运行及最终构建后的两项单独复跑中，`switchingMessagesStopsPreviousBeforeStartingNext` 的播放进度等待，以及 `controllerPreservesKeyboardDraftAndActivePlaybackWhenTextArrives` 的软件键盘高度断言失败；日志伴随模拟器音频设备错误，键盘 guide 高度为 34 点。最终复跑仍为 2 项失败、3 个断言问题。尚未证明根因，不能归为已修复或整组通过。后续历史锚点专项在 iPhone 和 iPad 均通过；没有用该通过结果覆盖上述失败。

iPad 的 UIWindow 绘制截图中，深色导航和系统玻璃对比度仍需实际屏幕复核；组件断言通过不等于人工视觉验收通过。四语言全流程、VoiceOver、降低透明度、增强对比度、动态窗口变更、全部媒体的双账号 UI 操作及真实权限测试未完成。本轮真实 HTTP 客户端联调使用文件媒体；服务端原有 nativeFormatsOverHTTP 在完整回归中覆盖原生媒体格式，两者不能互相替代。

### 复现入口

```sh
# 服务端及隔离真实 HTTP 联调
cd AzureFishServer
swift test -j 4
AZUREFISH_RUN_CLIENT_CHAT=1 swift test -j 4 --filter ClientChatHarnessTests

# 客户端持久队列与加密存储（回到仓库根目录）
cd ..
swift test --package-path SharePackage/AzureFishChat -j 4
python3 Scripts/sync-server-protocol.py --server AzureFishServer --check
```

最终音频复核采用 `AzureFish` scheme 的 `test`，筛选 `ChatAudioTranscriptionTests/switchingMessagesStopsPreviousBeforeStartingNext()` 与 `ChatAudioTranscriptionTests/controllerPreservesKeyboardDraftAndActivePlaybackWhenTextArrives()`。普通 `build` 后一次 `test-without-building` 因测试插件缺失无法启动，随后重建测试插件并实际执行；上述失败计数来自实际执行。

应用使用 `AzureFish` scheme；组件选择 `ChatOriginalUIIntegrationTests`、`ChatRichTextTests` 和 `ChatAudioTranscriptionTests/listResizesInPlacePreservesHistoryAnchorAndFollowsBottom()`。UI 选择 `ChatRegression` scheme 的 `ChatKeyboardUITests`、`ChatDraftUITests`，本次仅运行记录中列出的相关用例，不宣称整个 scheme 全量通过。
