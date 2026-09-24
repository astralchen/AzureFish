# iOS 26 iMessage 风格聊天页

`Chat` 是 Demo 内独立的一对一聊天页面，用来演示 QuickLayout、ListKit、AppLocalization、iOS 26 UIKit Liquid Glass、文本、音频、照片/视频、文件和网页链接消息与语音输入的组合使用。页面不复用或修改已有的 `UICollectionView` / `UITableView` 消息示例，也不为 QuickLayoutKit 增加公共 API。

该模块仅用于本地界面和交互演示，不接入上传或真实消息服务；添加网页链接时通过系统 Link Presentation 获取公开网页元数据。每次进入页面都会创建新的 `ChatViewModel`、页面附件存储与音频控制器，恢复与联系人 Alex 的固定示例会话。消息时间线和已发送附件只在本次页面生命周期内有效；未发送草稿独立保存在本机，支持离开页面及 App 重启后恢复。

## 调试日志

在 Xcode 的 Scheme → Run → Arguments → Arguments Passed On Launch 中添加并勾选 `-chat-debug-logs` 和 `true` 两项，才会输出 `[ChatScroll]` 等聊天诊断日志。未传参数、仅传参数名、值为 `false` 或其他值时不输出；Release 始终关闭。开关只读取本次进程参数，不会保存到用户偏好。滚动日志使用 `OSLog.Logger`，可在控制台按 `ChatScroll` 筛选。

## 草稿自动保存

正常入口按 `demo.chat` 会话标识保存一份草稿，不增加草稿列表。`ChatViewController` 的注入初始化支持 `conversationID` 和 `draftStore`；注入入口默认关闭持久化，避免测试共享用户数据。草稿 UI 测试使用 `-chat-draft-session <独立标识>`，可与既有媒体 fixture 参数组合。

- `ChatDraftSnapshot` 保留有序正文、四种语义富文本格式、空格换行、内联附件、媒体组及独立语音预览。未完成导入、失败附件、正在录音、播放进度和麦克风会话不进入快照。
- `ChatDraftCoordinator` 对正文编辑防抖 300 毫秒；附件就绪、清空、页面退出和 App 进入后台立即提交。发送被 ViewModel 接受后消费草稿；后续消息发送失败沿用时间线的重试入口。
- `ChatDraftStoring` 的读、写、删除在调用时入队，后台串行执行。正式存储位于 `Application Support/ChatDrafts`，会话目录名经过散列；JSON 仅包含相对资源路径。先复制资源，再原子替换清单并递增版本，最后回收失去引用的资源。文本修改复用现有副本。
- `PageAttachmentStore.acquireFileLease()` 让已排队的保存或恢复任务暂时保留页面文件；退出、附件删除仍立即清理业务状态，实际文件删除等待最后一个租约释放。旧保存不能越过后续清空，也不能晚于新页面的恢复读取。
- 恢复期间暂时禁用输入，随后一次性重建编辑器与附件控制器，不自动弹键盘或播放。原件缺失只跳过对应项目，Live Photo 缺少配对视频时跳过整个项目；图片和视频缩略图可以重建，文件及链接预览沿用现有异步补全。
- 磁盘错误保留上一份完整快照；保存失败、无法恢复和部分附件缺失有中英阿文反馈。异常终止进程时，只保证恢复最后一次成功落盘的版本。

`ChatDraftTests` 覆盖存储往返、资源复用、会话隔离、故障、文件租约及控制器恢复；`ChatDraftUITests` 已加入 `ChatRegression`，覆盖返回和重启恢复、混合媒体预览与发送、取消返回及手动清空，并保留截图。

Demo 应用、单元测试和 UI 测试目标的 deployment target 均为 iOS 15.0。`Chat` 页面入口要求 iOS 26.0 及以上，使用 iOS 26 原生玻璃 API。可用性按具体声明及其依赖标注：普通模型、协议和独立辅助逻辑不添加 iOS 26 限制；使用 iOS 16 / 17 API 的类型按实际最低版本标注；玻璃界面、现代语音识别及依赖它们的控制器、扩展和预览保留 iOS 26 限制。主菜单在旧系统隐藏聊天入口，路由也检查系统版本。媒体层保留旧版语音识别后端，用于现代识别服务不可用时回退；聊天页面不在 iOS 15–25 运行。聊天单元测试通过 Swift Testing 条件跳过，聊天 UI 测试和真实语音集成测试通过 `XCTSkip` 跳过旧系统。

## UI 布局约定

本目录新增或修改常规 UI 时优先使用 `QuickLayoutKit`、`QuickLayout` 与 `ListKit`，沿用现有页面的布局方式：

- 页面与组件使用 `QuickLayoutHostingController`、`QuickLayoutView` 及 `HStack` / `VStack` / `ZStack` 描述层级、尺寸、间距和安全区域；玻璃内容使用 `QuickLayoutVisualEffectView`，保持原生 effect 的 `contentView` 层级。
- 时间线、附件分页等集合内容优先交给 `CollectionListAdapter`，使用稳定 Row 身份管理注册、复用与更新。滚动、展示及专用分页尺寸回调通过 ListKit 的 delegate 转发；不再额外维护一份手写 data source。
- 少量连续排列的预览控制按钮使用 `QuickLayoutScrollView` / `ScrollView` 描述内容与滚动范围，避免逐个按钮计算 frame。
- 手动几何仅用于明确依赖像素／坐标的行为，例如图片缩放与居中、`AVPlayerLayer`、气泡遮罩、卡片堆叠手势、键盘／照片面板桥接和自定义转场。普通标题、按钮、播放条和文档占位布局不采用逐控件 frame 排版。
- 自适应媒体 Cell 必须将 QuickLayout 测量结果写入布局属性，并在真实 ListKit 列表中验证；仅验证脱离列表的单个 Cell 尺寸不足以发现估算行高导致的内容越界。

## 目录结构

沿用 `VoiceRoom` 的职责分层，视图再按功能分组：

```text
Chat/
├── Controllers/          页面、附件预览与系统选择器协调
├── Models/               消息、附件与预览请求模型
├── ViewModels/           会话状态与消息流程
├── Views/
│   ├── Header/           联系人导航标题
│   ├── Chat/             时间线、消息气泡与送达状态
│   ├── Composer/         输入栏与录音面板
│   ├── Attachments/      TextKit 附件与文件、网页卡片
│   └── Preview/          附件分页、预览页面与缩略图导航
├── Animations/           附件展开与交互关闭转场
├── Support/              附件存储、音频、发送、保存与预览数据
└── README.md
```

`Controllers` 负责页面及系统选择器的展示、回调和生命周期协调；
`Support` 放置音频、存储等能力实现及页面辅助协调器。
视图与同一职责下的 Cell、布局和私有辅助类型保留在对应功能目录，
`DEBUG` 预览保留在对应功能目录，与该组组件一起维护。

## 文件职责

沿用 `VoiceRoomViewController+Interaction`、`GiftSheetView+Rendering`
等文件的组织方式：主文件保留存储属性、初始化、生命周期和 UIKit 重写入口，
同一类型的实现按职责放入 `类型名+职责.swift`。独立模型、视图、Cell 和服务按类型命名。
跨文件扩展共同使用的实现成员采用模块内部可见性；只在单个文件使用的辅助实现继续保持 `private`。

页面入口保留 `ChatViewController`、`ChatViewModel`；内部类型按具体职责命名，
不重复添加 `Chat` 前缀，例如 `ComposerView`、`AudioController`、`MediaBubbleCell`。
消息方向与送达状态使用 `MessageDirection`、`MessageDeliveryState`，附件预览相关
类型使用 `AttachmentPreview` 前缀，组件预览数据使用 `ConversationPreviewData`。
文件名与主类型一致，同一类型的扩展保持 `类型名+职责.swift`；测试套件及
`ChatRegression` scheme 保留功能名称，便于筛选聊天回归。
同时导入 Swift Testing 的测试使用 `Demo.Attachment` 引用消息附件，避免与测试框架的 `Attachment` 同名。

| 目录 | 文件或文件组 | 职责 |
| --- | --- | --- |
| `Controllers` | `ChatViewController.swift` | 页面组合、初始化、生命周期、本地化与方向刷新。 |
| `Controllers` | `ChatViewController+Interaction.swift` | 绑定用户动作、发送混合草稿、文件和链接入口。 |
| `Controllers` | `ChatViewController+AttachmentPreview.swift` | 附件浏览请求、来源定位、取消和保存失败反馈。 |
| `Controllers` | `ChatViewController+Binding.swift` | ViewModel 绑定、键盘和底部遮挡、媒体文案与错误反馈。 |
| `Controllers` | `PhotoPickerController.swift`、`+Import`、`+SheetHost` | 系统照片选择与草稿状态、异步文件导入及元数据、独立面板宿主。 |
| `Controllers` | `DocumentController.swift` | 文件选择、网页元数据、缩略图和文档草稿生命周期。 |
| `Controllers` | `AttachmentPreviewController.swift`、`QuickLookPreviewController.swift` | 自定义附件浏览页面与系统 Quick Look 入口。 |
| `Models` | `Message.swift`、`MessagePresentation.swift` | 消息载荷、方向及送达状态；时间线展示、稳定身份与刷新身份。 |
| `Models` | `Attachment.swift`、`AudioAttachment.swift`、`MediaAttachment.swift` | 统一附件、文件与链接、音频、有序图片视频组及媒体草稿。 |
| `Models` | `ComposerModel.swift` | 输入栏文案、附件类型、编辑片段、用户动作与媒体状态。 |
| `Models` | `RecordingPolicy.swift`、`PlaybackState.swift`、`MediaFailure.swift` | 录音边界及固定波形槽位、播放快照、媒体错误。 |
| `Models` | `MediaStrings.swift`、`MediaStackPolicy.swift`、`AttachmentPreviewModel.swift` | 媒体文案、纯堆叠交互算法、预览请求及路由规则。 |
| `ViewModels` | `ChatViewModel.swift`、`+Sending`、`+Replies`、`+Rendering` | 会话状态与依赖；发送重试和回执；顺序回复及取消；时间线物化和发布。 |
| `Views/Header` | `ContactTitleView.swift` | 联系人头像、名称与副标题。 |
| `Views/Chat` | `ConversationView.swift` | ListKit 时间线渲染、可见内容刷新、滚底与方向刷新。 |
| `Views/Chat` | `TextBubbleView.swift`、`TextBubbleCell.swift`、`TimestampCell.swift` | 文本气泡、可复用消息 Cell 与时间标记。 |
| `Views/Chat` | `TypingBubbleView.swift`、`TypingCell.swift` | 输入中动画及对应 Cell。 |
| `Views/Chat` | `WaveformView.swift`、`AudioBubbleView.swift`、`AudioBubbleCell.swift` | 波形绘制、音频气泡和播放进度、音频 Cell。 |
| `Views/Chat` | `MediaMessageView.swift`、`+CardView`、`+Interaction`、`+Rendering` | 媒体气泡状态和 UIKit 入口、内部卡片、拖拽换层、卡片内容与几何。 |
| `Views/Chat` | `MediaBubbleCell.swift`、`DocumentBubbleCell.swift`、`DeliveryStatusView.swift` | 媒体及文档消息 Cell、各类消息共用的状态与重试控件。 |
| `Views/Composer` | `ComposerView.swift` | 输入栏存储状态、玻璃容器、布局入口和生命周期。 |
| `Views/Composer` | `ComposerView+Layout.swift`、`+Configuration` | 尺寸与布局规则、子视图外观和按钮配置。 |
| `Views/Composer` | `ComposerView+Editor.swift`、`+Rendering` | 富文本及附件编辑、文本代理；录音/听写/草稿状态渲染。 |
| `Views/Composer` | `ComposerView+Interaction.swift`、`+RecordingHint` | 附件菜单及按钮事件；录音不可用提示及延时清理。 |
| `Views/Composer` | `ComposerTextView.swift`、`ComposerHitButton.swift`、`MediaDraftStripView.swift` | TextKit 编辑入口、按钮命中区域、媒体草稿预览条。 |
| `Views/Attachments` | `TextAttachment.swift` | TextKit 2 附件、按文本布局管理器缓存和提供附件视图。 |
| `Views/Attachments` | `AttachmentCard.swift`、`LinkPreviewView.swift`、`AttachmentThumbnailView.swift`、`DraftRemoveButton.swift` | 文件和网页卡片、链接预览、缩略图与附件删除按钮。 |
| `Views/Preview` | `AttachmentPagingLayout.swift`、`AttachmentThumbnailStripView.swift`、`AttachmentPreviewPage.swift` | 分页几何、缩略图导航、图片缩放和文件/视频页面。 |
| `Animations` | `AttachmentPreviewTransition.swift` | 来源卡片展开、交互关闭、取消与离屏回退。 |
| `Support` | `AudioController.swift`、`+Recording`、`+Playback`、`+Dictation`、`+AudioSession`、`+ReplySynthesis` | 音频资源与生命周期、录音、播放、听写、音频会话和模拟回复合成。 |
| `Support` | `SystemPermissionProvider.swift`、`SystemAudioSessionController.swift` | 可注入的系统权限与音频会话接口及实现。 |
| `Support` | `SpeechConfiguration.swift`、`SpeechRecognitionService.swift`、`AudioTranscription.swift` | 语音后端及语言规则、实时识别、文件转写与串行调度。 |
| `Support` | `AttachmentStore.swift`、`AttachmentSaving.swift`、`MessageSending.swift` | 页面附件所有权、系统保存与导出、模拟消息发送服务。 |
| `Support` | `BottomObstructionCoordinator.swift`、`PasteCoordinator.swift` | 键盘/照片面板遮挡采样、粘贴类型识别与导入协调。 |
| `Support` | `PlaybackCoordinator.swift`、`AttachmentPreviewPlayer.swift`、`MediaStackStateStore.swift` | 音视频播放互斥、预览播放控制、消息媒体封面索引。 |
| `Support` | `ConversationPreviewData.swift`、`AttachmentSavePreviewFixtures.swift` | 确定性组件预览与附件保存场景数据。 |

依赖方向保持为：

```text
ViewController / Views -> ViewModel -> Models
              |
             +-> Attachment Store
              |
              +-> Audio Controller -> AVFAudio / Speech
              |
              +-> Photo Picker -> PhotosUI / ImageIO / AVFoundation
              |
              +-> Bottom Obstruction -> UIKeyboardLayoutGuide / CADisplayLink
```

ViewModel 不持有播放器、录音器或 UIKit 对象。输入栏通过单一
`ComposerAction` 上报用户事件，时间线通过单一
`MessageAction` 上报消息操作；两者只渲染页面协调器发布的状态，
不维护第二份录音、转写或播放业务状态。

## 消息模型与回复流程

消息内容按以下载荷区分：

- `.localized(key:)`：固定示例或模拟回复，运行时切换语言后重新解析。
- `.userText`：用户输入或语音转写形成的原始文本，切换语言时不改写。
- `.richText`：由 `MessageText` 保存有序文字片段与粗体、斜体、下划线、删除线，可局部叠加；不存储 UIKit 字体、颜色或附件。选中文字后，通过系统编辑菜单中的“文本格式”切换。发送、失败重试和语言切换保留格式；气泡按方向和 Dynamic Type 生成属性。混合附件草稿按原顺序拆段，并保留格式及用户空白。文字动画不在此格式模型内。
- `.attachment(.audio)`：统一附件边界中的音频载荷，包含稳定附件 ID、本地可回放文件 URL、精确时长与归一化波形采样。用户录音为 AAC `.m4a`，模拟语音回复为 `.caf`。
- `.attachment(.mediaGroup)`：一次有序选择形成的 1–20 项媒体，保存稳定组/项目 ID、资源标识、页面拥有的原文件与缩略图 URL、像素尺寸以及图片/视频类型；视频类型额外保存有效时长。

- `.attachment(.file)`：文档或从录音转换的普通文件，保存稳定 ID、原始文件名、真实 UTType、大小和可选缩略图。
- `.attachment(.link)`：HTTP(S) URL、可选网页标题与图片。无元数据时保留可打开、可发送的 URL 卡片。

音频 Model 不包含 `AVAudioPlayer`、`AVAudioRecorder` 或 UIView。ListKit 的消息 ID 继续作为稳定身份；刷新身份同时包含附件元数据、消息方向和送达文案。播放进度属于页面级瞬时状态，由音频控制器直接更新可见 Cell；滚出屏幕后重新出现的 Cell 会在配置时读取同一份播放状态。

文本和全部附件共用 `sending → delivered → read` 状态，以及 `sending → failed → sending` 重试分支。每次发送先插入消息并显示进度，通过可注入的 `MessageSending` 获取送达结果。默认本地服务在约 250 ms 后模拟确认；没有真实上传、Apple 回执或网络连通性推断。

1. 所有发送中的消息显示“发送中…”和进度；所有失败消息保留红色感叹号、“尚未送达”和至少 44 × 44 pt 的重试点击区。较新的成功消息不会隐藏旧失败。
2. 普通“已送达／已读”仅显示在最新 outgoing 下。重试复用原消息 ID、附件和发送时间，不新增气泡，不触发发送动画或强制滚到底部。
3. 模拟送达后等待约 300 ms，独立产生阅读回执，再准备对应类型的回复。已读只推进已经送达的消息，不能把发送中或失败消息标为已读；乱序或重复回执不能倒退状态。`readReceiptsEnabled: false` 时，即使收到回复也保持“已送达”。
4. 仅文字回复显示键入指示器，并等待约 900 ms。媒体、文件、链接和语音使用相同的准备等待但不显示键入；语音合成与准备等待并行，失败时回传具有新附件 ID 的原语音。
5. 连续和混合发送按原顺序排队，送达回调乱序不改变正常回复顺序；失败项不阻塞后续消息，手动重试成功后重新入队。照片／视频组保留数量、项目顺序和格式；文件和链接保留原载荷。附件只读资源共享页面生命周期，回复使用独立附件和媒体项目 ID。
6. 页面离开时取消发送、阅读等待、语音合成和回复队列，并以尝试标识和会话代次屏蔽迟到回调。任务异常必须清除键入和工作状态；附件仍由页面存储统一清理。

`DeliveryStatusView` 为文字、语音、媒体、文件和链接共用状态视图，支持中英阿本地化、RTL、大字号和 VoiceOver。状态更新使用独立 `.messageStatus` 原因；浏览历史时恢复可见锚点，不重置媒体组索引。列表通过 ListKit 的 `.serial` 调度完成每次可见刷新，并对变化消息重测高度，防止连续送达/已读/键入更新被合并后遗留旧状态。主动发送的滚到底部意图保留至最后一份列表更新完成。

Debug 启动参数 `-imessage-fail-first-send` 让本页面第一条消息确定失败，便于实际点击红色状态验证重试；下一次尝试正常成功。默认不注入故障。此入口和约 250/300/900 ms 的延时均为 Demo 测试规则。

参考 Apple 官方说明：[阅读回执](https://support.apple.com/zh-cn/guide/iphone/iph5e713a045/26/ios/26)表示收件人查看消息，[发送失败](https://support.apple.com/zh-cn/118433)显示红色感叹号并可重试。Apple 未在这些文档中规定本 Demo 的延时、回执集中显示或附件准备动画规则。

音频模拟回复使用 `AVSpeechSynthesizer.write(_:toBufferCallback:)` 获取 PCM buffer，并写入页面临时目录中的 `.caf` 文件。该流程只生成附件，不调用 `speak`，不会自动从扬声器朗读，也不需要麦克风或 Speech Recognition 权限。简体中文、英语和阿拉伯语分别使用 `zh-CN`、`en-US` 与 `ar-SA` 的系统默认可用声线；不要求下载增强声线或固定 voice identifier。

合成器根据音频帧数和采样率计算精确时长，并从 PCM 振幅压缩出 36 个归一化波形槽位。生成的 incoming 音频继续使用现有单实例播放器，只有用户点击消息气泡后才开始播放。已经生成的语音附件不会在运行时切换语言后重新合成；后续回复使用新的应用语言。

`ChatEquivalentReplyTests` 覆盖混合批量与连续发送顺序、单图/视频、媒体组元数据、音频文件/文档/链接、独立身份、语音回退和取消后的迟到回复。2026-09-10 在 iPhone 17 Pro（iOS 26.5）运行相关 7 个测试套件，91 项通过、0 失败、0 跳过；实际界面确认两图发送后收到两图回复、保存入口和原图预览。真机及全部附件的逐项手动交互本轮未执行。

本次消息状态改造后，`ChatMessageStatusTests` 连同媒体、文档、保存、同类型回复及语音相关回归共 8 个套件、99 项测试通过，0 失败、0 跳过（iPhone 17 Pro / iOS 26.5）。新增可见 Cell 连续刷新用例验证旧回执清除及最终已读；实际界面完成发送失败、点击重试、已读和收到回复。中途一轮键盘回归因模拟器软件键盘隐藏失败，恢复显示后完整复验通过；真机和真实消息服务未执行。

只有最新一条 outgoing 消息显示“已送达/已读”。时间线第一条消息必定带时间标记；后续消息与上一条间隔达到 5 分钟时插入新的时间标记。

## 音频消息自动转写

收发双方的 `.audio` 消息先进入时间线，再异步识别已提交的音频文件。纯音频气泡
立即可播放；整段识别成功后，在同一气泡下方追加完整文本。识别期间没有占位文字，
权限拒绝、无有效语音或识别失败均保留纯音频，不弹出业务错误提示，也不自动重试。
模拟回复识别实际合成文件，不把合成原文当作识别结果。已转换为 `.file` 的录音不参与转写。

`AudioAttachment.transcript` 默认为 `nil`，参与现有附件刷新身份。
ViewModel 的 `updateAudioTranscript(_:messageID:attachmentID:)` 校验双重身份后原位更新，
不改变消息 ID、文件、时间、已读状态，也不触发新回复。播放进度仍由页面播放器维护。
列表使用专用 `.audioTranscript` 更新原因重新测量高度：底部用户保持贴底，浏览历史时
保存可见消息锚点，避免文字出现后突然跳到最新消息。

页面级 `AudioTranscriptionCoordinator` 观察统一时间线，按消息/附件身份去重并串行
调用可注入的 `AudioFileTranscribing`。语言固定为入队时的应用语言，后续语言切换
不改写已有识别文本。新消息不取消旧识别，退出页面先取消识别并屏蔽迟到回调，再清理附件。
转写任务在发送的同步调用栈之后执行，保留“插入消息 → 提交附件 → 退出预览”的所有权顺序。

文件识别与输入框实时麦克风识别使用独立实例，不启动麦克风、不配置录音或播放会话。
iOS 26 优先使用 `SpeechAnalyzer` 的文件输入，先通过 `AssetInventory.reserve(locale:)` 预留语言，
再准备对应模型；语言/模型准备不可用时自动回退至
`SFSpeechURLRecognitionRequest`。旧后端需要系统 Speech 授权，本机识别可用时优先使用，
本机请求失败后允许 Apple 在线识别。显式指定后端和取消操作不触发后端回退；现代后端
准备完成后的运行错误也不重启识别。保留旧版识别接口作为回退，聊天功能仍要求 iOS 26.0。

音频气泡参考 iPhone 16 Pro：圆形播放控件、弹性波形、`mm:ss` 时长及下方自然换行文本，
收发方向有对应的底部尾巴。在 402pt 宽、默认字体下，气泡约宽 281pt，纯音频总高 82pt
（含 6pt 尾巴）；播放图形为 28pt，点击区域为 44pt，波形占满按钮与时长之间的可用宽度。
时长及转写采用可缩放的 15pt 字体，浅色模式接收背景为 #E9E9EB，音频蓝色为 #418EF6。
保留现有消息语义边距和送达文案对齐，支持 RTL、动态字体和 VoiceOver。
消息气泡和发送前音频预览在播放时显示当前播放时间（`00:00 → 00:01 → …`），
暂停时保留时间，继续播放后递增，重播从零开始；尚未播放或停止重置后显示总时长。
时间由现有播放器进度驱动，不另启 UI 计时器；数字等宽，避免每秒变化时挤动波形。
预览与所有消息共用一个播放器，切换目标先停止旧音频，将时间恢复总时长、波形归零、按钮恢复播放；暂停、结束回调只更新对应目标，
不会覆盖另一个预览的播放位置。消息播放状态同时校验消息 ID 和附件 ID。
`ChatAudioTranscriptionTests` 覆盖异步回填、收发/批量队列、取消/失败、语言冻结和复用排版；
替身测试只证明状态与布局，真实语音识别和参考截图比对须单独验收。

## 照片/视频选择与媒体消息

“+ → 照片”使用 UIKit `PHPickerViewController`，同时选择图片和视频，最多 20 项。
配置采用 `.continuousAndOrdered` 与 `.current` 表示模式。通过 `edgesWithoutContentMargins = [.top, .bottom]`
隐藏顶部导航附件区（数量提示、照片／精选集切换及操作按钮）和底部工具栏（选项、搜索、已选数量和位置提示）。
照片选择器视口完整贴合宿主边界，由系统配置管理顶部内容边距；不再负向偏移视口或安全区，以免第一行被裁剪。
Sheet 拖动条叠加显示而不单独占用高度。通过 `.selectionActions` 禁用重复的确认／清除操作，并关闭 staging area
与敏感内容干预界面。选中即更新 Composer 草稿，使用草稿上的 × 移除单项，使用输入框发送按钮发送。
发送成功后清空已发送草稿及系统网格的勾选，照片面板保持展开、当前档位和滚动位置，便于继续选图发送；
不主动切换键盘焦点。发送未被受理时保留草稿与勾选。点击正文输入框仍按原有流程切回键盘。
提交时先推进草稿版本再取消系统勾选；无系统照片 ID 的附件跳过取消勾选调用，避免 PHPicker 对空数组触发断言。

2026-09-13 连续发送回归：使用已安装 Xcode 26.5，以命令级 `DEVELOPER_DIR` 在 iPhone 17 Pro / iOS 26.5
构建并通过媒体、输入框焦点两套单元测试，共 36 项（`/private/tmp/PhotoSend-unit-final.xcresult`）。
两条模拟器 UI 流程通过：预览返回保持原档位（`/private/tmp/PhotoSend-ui.xcresult`）；发送照片和正文后面板不下退、
同一系统照片连续选择发送两次、草稿与勾选清空（`/private/tmp/PhotoSend-ui-final.xcresult`），结果包保留截图。
首轮发送 UI 发现空标识数组断言，加入保护后复验通过；真机验证未执行。

页面不请求完整照片库权限，
也不遍历或修改系统选择器私有视图层级。重新打开时使用资源标识恢复预选；选择数组、
全屏预览页序和发送模型始终保持用户勾选顺序。

资源通过 `NSItemProvider.loadFileRepresentation` 读取后立即复制到页面附件目录，不能
长期引用系统临时 URL。图片保留原文件，并通过 ImageIO 生成最长边不超过 1280px 的
JPEG 缩略图；视频验证视频轨道与正时长，通过 `AVAssetImageGenerator` 生成同样上限的
封面。模型只保存值类型和文件 URL，不保存 `UIImage`、`PHPickerResult`、
`NSItemProvider`、`PHAsset`、`AVAsset`、播放器或手势对象。

媒体草稿存在时，输入栏上层显示固定 156pt 高、按原件比例计算 80～208pt 宽、6pt 间距的横向预览条，下层继续使用
1–5 行文字输入，占位文字为“添加注释或发送”，清空媒体草稿后恢复“iMessage”；占位文字随页面语言切换。首项选中后即显示发送箭头，导入过程中保持该入口但禁用发送；所有项目完成导入后才启用发送。
继续追加照片或视频时同样保留发送箭头，不短暂切回语音转文字图标；清空全部草稿且正文为空时恢复听写入口。
2026-09-13 按钮状态回归在同一模拟器通过 37 项媒体与输入框焦点单元测试，覆盖首项导入、追加导入、就绪、移除、
清空的实际控件可见性，以及未就绪时拒绝发送（`/private/tmp/PhotoImportButton-unit.xcresult`）。
真实照片连续选择与发送 UI 流程通过（`/private/tmp/PhotoImportButton-ui.xcresult`）；真机未验证。
视频预览显示图标和 `m:ss` 时长，
删除按钮同步取消系统勾选并清理该项文件。录音中首次选中照片或视频会取消录音并删除临时录音文件；仅打开或关闭照片 Sheet
不会取消录音，也不会丢弃已经导入的媒体或文字。

音频处于待发送预览时选中照片/视频或添加文件/链接，停止试听并将录音文件所有权
移交文档控制器，音频控制器立即回到 idle。文件以普通 `.file` 附件插入原 `UITextView`，
真实格式仍为 `.m4a`；不再保留录音预览、波形或录音播放回调。仅开关面板不触发转换。
删除全部照片或媒体导入失败不会丢弃文件卡片，也不会恢复波形预览。

“＋ → 文件”可多选 JSON、PDF、音频等文件，异步复制到页面目录；“＋ → 链接”或粘贴
完整 HTTP(S) URL 可插入网页卡片，直接发送单独的网址也生成链接消息。文件卡片显示
Quick Look 缩略图（不可用时使用类型图标）、原文件名、类型和大小；网页使用系统
`LPLinkView`，元数据失败时仍可发送原 URL。点击文件用 `QLPreviewController` 预览，
常用文件使用统一自定义预览，音频文件在预览页内播放；点击网页打开 URL。此处不伪造 Notes/iCloud 协作卡片。

所有内联卡片由 `NSTextAttachment` / `NSTextAttachmentViewProvider` 参与原生排版，
可移动光标、在前后输入、通过删除键/选区删除/剪切移除，并提供 VoiceOver 打开和删除操作。
转换的录音、菜单导入和粘贴附件统一插入当前光标位置；选中内容被替换，完成后光标位于插入内容之后。
附件占独立段落；文件菜单保存打开时的选区，批量占位同步插入，重复更新不重复插入。录音预览转换的文件位于新插入内容之前。
输入框内的所有卡片右上角都有独立 44pt 删除区域，RTL 下也保持物理右上角；已发送消息不显示删除按钮。
卡片高度单独计入输入框，正文保持最多五行的增长规则；多附件超过窗口高度预算后在原编辑器内滚动。删除、撤销、迟到导入和元数据
回调不能恢复已失效文件。仅转换或更新卡片不主动取得键盘焦点。

附件与照片、视频及正文可以共存并发送。一次点击按“上方照片/视频组 → UITextView
中的文字/附件位置顺序”形成多条独立消息，整批只发布一次发送时间线更新，随后按原顺序逐条生成同类型模拟回复。
Composer 禁止发送未导入完成或失败的文件，ViewController 核对全部附件身份，ViewModel
先验证所有载荷再追加；失败完整保留草稿，成功后才提交文件并清空输入。自动附件字符与
排版换行不作为文字消息发送，有效文字段原样保留首尾空白，纯空白段跳过。

### 原生粘贴

`PasteCoordinator` 通过 `UITextPasteDelegate` 处理用户发起的粘贴，不在后台轮询剪贴板。
支持图片、视频、音频、文档及完整 HTTP(S) 网址；混合文字与网址保留为正文。同一提供器有多种表示时，
只选一项真实媒体/文件表示，随后才考虑 URL 或文本，不把 HTML/RTF 文本表示误转为文件。
整批内容按剪贴板顺序替换当前选区，文字与附件交错顺序保持不变；无选区时在光标处插入。
文本优先使用 `NSString` 类型化读取，兼容系统将文本物化为临时文件的提供器。
关闭智能插入空格并显式组合每项结果，防止系统在附件周围生成正文空格；附件替换遵循原生选区语义，
结束组合范围后只替换选中内容，未选中的组合文字保持一次且不丢失。
含附件的批次先结束空的原生粘贴事务，再在主队列统一提交，避免 UIKit 收尾继续按插入前的坐标修改草稿。
字符替换通过 `UITextInput.replace` 同步键盘上下文，再在一次 TextKit 编辑事务中写入附件属性；中间编辑回调不执行身份清理，避免 emoji 后插入时旧上下文覆盖卡片。
加载先显示可删除占位卡片，完成后按稳定 ID 原位更新。图片使用降采样缩略图，视频附带播放标志与时长，
导入逻辑复用照片选择器的媒体元数据处理。优先复制原始格式，只有 UIImage 表示时才保存为 PNG。
粘贴图片和视频各自成为单项媒体消息，不因相邻而合并。发送按附件切开正文，例如“文字 A → 附件 1 → 文字 B → 附件 2 → 文字 C”生成五条消息。
非纯空白文字段保留首尾空格、换行及内部换行，纯空白段不发送，系统生成的附件排版换行不属于正文。完整网址文字段在原位置转为链接消息。

`NSItemProvider.loadFileRepresentation` 返回的临时文件必须在回调结束前复制；复制后的文件才归页面所有。
导入失败保留可删除卡片并阻止发送；链接元数据失败仍可发送 URL。删除、离页或迟到回调不能留下孤儿文件或恢复卡片。
原生退格、剪切、选区删除和可见删除按钮共用身份清理路径；VoiceOver 提供打开和删除动作。
实际粘贴附件时沿用录音取消/预览转文件规则，不主动打开键盘，也不改变照片面板状态。
Apple API 依据：[UITextPasteDelegate](https://developer.apple.com/documentation/uikit/uitextpastedelegate)、
[文件表示的生命周期](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation(fortypeidentifier:completionhandler:))。

Apple 公开 API 依据：[TextKit 附件视图](https://developer.apple.com/documentation/uikit/nstextattachmentviewprovider)、
[富链接视图](https://developer.apple.com/documentation/linkpresentation/lplinkview)、
[Quick Look 缩略图](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator)。
[协作分享](https://support.apple.com/en-lamr/guide/iphone/iphf08c82a16/ios)需要来源应用的真实分享数据。
录音转换时机和附件优先的分条发送以本模块确认需求为准，未声称复现 Messages 私有实现。

已发送媒体按以下规则显示：

- 1 项不显示数量标题，媒体自身使用约 22pt 圆角和收发方向对应的消息尾巴；视频中央显示播放按钮。
- 2–20 项显示蓝色四宫格与“`N 个项目`”，主卡片为 216 × 300pt，并按附件实际数量显示最多五层卡片。已浏览项目逐层露在返回方向，未浏览项目逐层露在前进方向；每层水平偏移 8pt、垂直偏移 6pt，多项不绘制尾巴。
- 媒体原始顺序始终保持 `[0, 1, …, N-1]`。左滑进入下一项，右滑回到上一项，首尾阻尼回弹且不循环；可见卡片从原始顺序中截取包含当前封面的连续窗口，展示索引只存于当前页面的 `[MessageID: Int]` 状态，不修改附件数组。
- Cell 按媒体组实际数量绑定最多五张连续索引的卡片，并通过明确的 `layer.zPosition` 保证静止时主卡片最高。超过五项时可见窗口跟随当前封面移动。第 1 项时后置层只向前进侧展开；中间项同时在两侧显示已浏览和未浏览层；末项时后置层只向返回侧展开。cell 自适应高度包含标题、300pt 主卡片和全部层叠偏移，滑动不会改变列表 content size 或送达状态位置。
- 拖动期间保留已确认封面和卡片绑定：以开始时实际卡片宽度 `W` 为基准，向外达到 `0.60W` 时候选卡片盖到前面，回拖至同一临界值 `0.60W` 以下时原卡片立即重新盖到前面，不再设置额外回拖距离。可以反复跨界预览；穿过起点改向时重新计算相邻候选。原卡片水平跟手，以 `min(1, |x| / (0.60W))` 驱动缩放至 `0.72`、旋转至 `±10°`，视频图标随卡片同步变换。
- 仅松手确认切换：仍处于换层状态，或同向速度达到 `550pt/s`，才提交相邻封面；慢速回拖退出临界区及系统取消均回弹。确认时立即保存索引并仅回调一次，收尾不重复提交。提交使用 `0.28s / 0.86` 弹簧，回弹使用 `0.22s / 0.78` 弹簧，全程保持卡片不透明并连续收拢；减弱动态效果时关闭交互旋转、缩放和弹簧，改用 `0.16s` 简短过渡。这些参数是本 Demo 的参考图实现值，不是 Apple 私有参数。
- 同一消息重新布局或普通刷新保持拖动预览；尺寸、布局方向、媒体内容或消息身份变化会取消当前交互，已确认的索引仍保留。收尾完成后整理最多五张卡片的窗口，旧动画完成回调通过绑定身份及递增令牌校验；拖动和收尾期间不接受点击预览或重复切换。
- 点击主卡片或可明确命中的后置卡片，从对应原始索引进入全屏预览。图片页支持捏合和双击缩放；视频页使用 `AVPlayerLayer` 与自定义玻璃控件播放本地文件，离页时停止并释放播放器。

发送顺序固定为“读取完整草稿 → ViewModel 原子验证并追加 → 提交草稿”。任何项目
缺文件、缩略图、有效像素尺寸、视频轨道或正时长时都不产生部分消息，媒体和文字草稿
保持不变。照片面板单项导入失败只删除失败项，粘贴导入失败保留可删除卡片；页面退出时取消未完成任务并清理未发送草稿。

## 文本输入与语音转文字

普通输入状态由左侧独立 44 点“+”玻璃按钮和右侧输入胶囊组成。“+”使用 `UIMenu` 与 `showsMenuAsPrimaryAction`，展示“照片”和“音频”：照片同时承载图片/视频选择；存在文字或媒体草稿时，点击音频显示两秒清空提示。当前范围不包含相机拍摄或媒体编辑。

`UITextView` 的基础高度为 44 点，随内容扩展到最多 5 行，超过后在输入框内部滚动。空输入显示麦克风；裁剪后存在非空文本时显示原有发送箭头。存在媒体草稿时始终隐藏听写麦克风，并在全部导入完成后显示蓝色发送箭头。发送时保留有效文字段的全部原始空白和换行；纯空白段不会发送。

文本态和录音态使用独立的玻璃布局度量。文本态的 `inputGlassView` 使用 4 点
语义起始内边距、6 点语义结束内边距和 4 点内容间距；尾部操作区域固定宽
44 点，麦克风高 40 点。文本发送与音频预览发送按钮统一使用 38 × 28 点
视觉 frame、胶囊圆角和至少 44 × 44 点命中区域，因此发送按钮呈横向胶囊而不是
正圆。无文字或单行输入时，发送按钮在输入胶囊的文本行内垂直居中；录音前提示中的禁用发送按钮同样居中。多行文本发送按钮与 `inputGlassView` 底边保留 6 点间距；
麦克风按钮保留 2 点底部间距。
录音态不复用这些值。录音和预览玻璃统一使用 64 点高度与 14 点四边基础
内边距；实时录音波形在该内容边界内额外保留 14 点语义起始留白。

文本焦点由用户主动操作决定。附件菜单与录音流程不缓存菜单打开前的焦点，也不在
菜单关闭后调用 `becomeFirstResponder()` 恢复键盘。文本编辑器保留在原视图层级中，
录音和音频预览时只把文本玻璃设为透明，不禁用其交互属性，避免 UIKit 结束编辑；
透明容器不参与触摸命中，并从辅助功能遍历中隐藏。已有文本焦点应连续保留，原本
没有焦点时也不主动取得焦点。44 点文本栏切换到 64 点录音栏仍会产生正常的高度变化。

点击尾部麦克风时才请求麦克风和 Speech 权限：

1. 授权和识别资产准备期间显示准备状态，不提前修改草稿。
2. 转写期间尾部按钮变为红色停止按钮，最新 partial result 替换当前活动转写片段，不重复追加同一句。
3. 点击停止、中断或识别结束后保留最后文本为普通草稿，不自动发送。
4. 用户开始手动编辑时，输入栏先通知媒体协调器停止转写，再接受编辑，已取消代次返回的异步结果不会覆盖草稿。
5. 没有识别结果时恢复空输入；权限或识别失败不发送任何消息。

系统后端由媒体服务选择，ViewController 不判断系统版本：

- iOS 26+ 优先使用 `SpeechAnalyzer`、`SpeechTranscriber` 和 `AssetInventory`。识别前通过等价 locale 解析支持语言，并在需要时安装本地语音资产；如果 Analyzer 在当前设备、模拟器、语言或资产状态下无法启动，则清理未完成状态并回退到 `SFSpeechRecognizer`。只有两个后端都无法启动时才显示“语音识别不可用”；部分 Simulator Runtime 不提供任一后端，降级不能伪造识别结果。
- 兼容回退后端使用 `SFSpeechRecognizer` 与 `AVAudioEngine`。支持设备端识别时设置 `requiresOnDeviceRecognition`；不支持时允许系统在线识别。
- App 的英语、简体中文和阿拉伯语分别映射为 `en-US`、`zh-CN` 和 `ar-SA` 识别 locale。

## 音频录制、预览与发送

选择“+ → 音频”时，输入栏必须完全为空。文字（包括空格、换行）、照片、视频或正在导入的媒体草稿存在时，“音频”菜单仍可点击，但只显示“若要录音，请清除输入栏。”：文字与媒体预览暂时隐藏，输入玻璃收为 44 点单行，加号与发送箭头置灰，编辑和草稿操作暂停。两秒后按最新草稿恢复内容、照片顺序、光标、文本滚动位置和原高度；重复触发不会延长提示，媒体导入仍正常更新。此过程不启动录音、不请求权限、不清空或发送草稿，也不改变用户已有的键盘焦点。页面离开、视图移除或切换其他音频状态会取消提示，过期回调不能覆盖新状态。键盘语音转文字入口不受此规则影响。

输入栏为空时，选择“+ → 音频”后保留键盘状态，输入栏临时切换为整行录音面板。录音态使用 16 点页面水平边距、64 点胶囊高度和 8 点上下边距。录音和预览玻璃中的内容统一使用 14 点四边基础内边距，实时录音波形在共享内容边界内额外保留 14 点语义起始留白，因此波形距玻璃起始边为 28 点；36 点停止按钮以及预览态的播放、发送控件均从同一条 14 点内容边界定位。两种媒体内容栈都显式声明垂直内边距，不依赖父视图的隐式居中。录音和预览波形在 30 点布局槽内垂直居中绘制为 2–12 点高的紧凑柱形，消息气泡波形不受此限制。停止按钮的视觉尺寸遵循设计图，同时把实际命中区域对称扩展到 44 点。固定的媒体态度量不会改变普通文本输入栏的 44 点基础高度：

1. 首次使用时请求麦克风权限。
2. 使用 AAC `.m4a`、44.1 kHz、单声道、96 kbps 语音配置录音，并启用 metering。
3. 每约 50 毫秒采样一次音量；录音 UI 从第一帧起固定使用 60 个波形槽位，以 2 点柱宽和 2 点间距匹配 iPhone 16 Pro 设计图，并将语义起始侧 28% 的旧采样绘制为浅红色。采样不足时用最低振幅补齐，超过上限后滚动保留最新采样，因此录音过程中柱宽和胶囊内边距都不会变化。`#Preview` 使用相同的固定槽位转换，避免 Canvas 与真实录音状态出现不同柱宽。最终附件另行压缩为固定数量的归一化波形采样，避免数据随时长无限增长。
4. 录音态显示红色实时波形、`m:ss` 时长和红色停止按钮；达到 120 秒时自动停止。
   同一次录音中的计量、波形和时长更新只刷新现有内容，不重新计算 Composer
   或父视图布局，因此 16 点页面边距、14 点四边基础内边距和停止按钮位置在
   整段录音期间保持不变。
5. 少于 1 秒的录音立即删除并显示“录音时间太短”，随后恢复原文本草稿。
6. 有效录音进入预览：左侧为独立的 44 点玻璃取消按钮；胶囊内依次为 36 点次级填充播放/暂停按钮、静态波形、带次级填充背景的总时长和统一的 38 × 28 点胶囊发送按钮。紧凑视觉控件均保留至少 44 点的实际命中区域。
7. 取消会停止预览并删除文件；发送会把附件交给 ViewModel。两种操作都会恢复原文本草稿，音频操作不会顺带发送或清空草稿。

预览和时间线共用一个 `AVAudioPlayer`，同一时间最多播放一个附件。再次点击当前附件会暂停并保留进度，再次点击从该进度继续；点击另一条音频会停止上一条并切换目标。播放状态保存在媒体协调器中，因此 Cell 滚出屏幕不会停止播放，Cell 复用或重新出现时会从页面级状态恢复按钮与波形进度。时间线中的文本和音频气泡共用 12 点页面水平边距；音频气泡在最大宽度框内显式按消息方向贴语义边缘，发出音频、发出文本及其送达状态必须落在同一条尾边，RTL 时对应镜像到语义起始侧。

## 临时文件与页面生命周期

每个 `PageAttachmentStore` 创建独立临时目录：

- 有效录音先注册为草稿；取消、过短或编码失败的录音立即删除。
- 照片/视频原文件与缩略图使用同一个媒体组草稿 ID；删除单项时只清理该项，取消草稿时整体清理，已发送后整体提交。
- 发送时先由 ViewModel 验证附件，成功追加消息后才把草稿转为已提交附件；发送
  失败不会清空预览。
- 合成失败、取消、空 buffer 或零时长产生的部分 `.caf` 文件立即删除。
- 已发送录音和成功生成的回复音频仍位于页面目录中，供时间线回放。
- 页面离开时停止录音、转写和播放并释放音频会话。
- 页面及音频控制器销毁时取消异步任务、移除通知观察、停止媒体对象，并由附件
  存储删除整个临时目录。

因此，音频和照片/视频消息都不会跨页面恢复，也不会上传、写入业务缓存或进入真实消息存储。

## 音频会话、中断与失败处理

录音、实时语音输入和音频播放由同一个音频控制器互斥管理。开始录音或实时语音输入前停止并重置当前播放，两者不能同时占用麦克风。已发送消息的文件转写由独立页面队列管理，不占用麦克风，也不打断播放。

聊天页的 `viewWillDisappear` 始终停止播放：跳转、全屏覆盖、切换 Tab 均恢复总时长，
返回可见状态不自动续播。只有确认退出聊天或关闭父容器后的 `viewDidDisappear` 才清理附件与页面任务，
临时覆盖和取消交互式返回不会删除文件。打开照片选择器、文件选择器、文件/媒体预览也先停止音频，
避免半屏呈现不触发页面消失时漏停。正在播放的文件失效或解码失败时停止、重置并反馈失败。

音频会话使用 `playAndRecord`、`spokenAudio`、默认扬声器和蓝牙免提路由；空闲时通过 `notifyOthersOnDeactivation` 释放会话。

来电、其他音频会话中断或 App 进入后台时：

- 录音达到 1 秒则停止并保留为预览，否则删除并恢复文本态。
- App 进入后台时停止并重置播放，前台恢复不自动续播；临时系统音频中断则暂停并保留进度，不自动恢复。
- 语音转写停止并保留最后草稿，不自动重启麦克风。
- 耳机等旧输出路由移除时立即暂停播放。

音频控制器与视频预览共享页面级 `PlaybackCoordinator`。开始播放前同步停止旧所有者，
音频切视频时恢复音频总时长；视频切音频时停止并解除页内播放器。
视频暂停期间仍保留所有权；切换对象和关闭时释放，不自动恢复旧对象。
打开媒体预览前也停止并重置聊天音频。视频使用 `.playback` / `.moviePlayback` 会话，
由预览播放器管理激活；两个播放器各自仅释放自己激活的会话，闲置时不会误关闭其他所有者的会话。
视频退后台暂停且不自动续播，关闭播放器时释放播放器，禁用画中画；返回聊天后音频仍需手动播放。

权限只在首次触发对应功能时请求。录音发送需要麦克风权限；实时语音输入同时需要麦克风和 Speech 权限；文件转写仅在所选后端需要时请求 Speech 权限。拒绝或受限制时显示英语、简体中文或阿拉伯语说明；可恢复的拒绝状态提供“打开设置”。录音、播放、实时语音输入、语音合成资产或文件失效也通过本地化错误反馈处理，不自动发送消息。文件转写失败或权限拒绝则静默保留纯音频。

权限声明位于 `InfoPlist.xcstrings`：

- `NSMicrophoneUsageDescription`：录制音频消息及语音输入。
- `NSSpeechRecognitionUsageDescription`：把讲话转写为消息草稿，并为收发的音频消息生成文字。

## 列表布局、滚动与键盘/照片 Sheet

- 文本和音频气泡都以可用行宽约 75% 为上限；单媒体最大宽度 252pt，多媒体层叠完整外框为 232pt。
- incoming 位于语义 `leading`，outgoing 位于语义 `trailing`；RTL 下位置、尾角、送达状态与控件顺序按语义镜像。
- outgoing 音频沿用蓝色消息色，incoming 音频使用系统次级填充色。
- 送达状态与 outgoing 气泡的语义尾端对齐，不能使用屏幕边缘独立定位。
- 首次加载和主动发送后滚到底部；收到回复、本地化刷新、输入栏高度或模式变化时，只有用户原本接近底部才跟随滚动。
- 用户浏览历史时，本地化刷新保存并恢复可见锚点，录音/预览状态变化不会强制把列表拉到底部。
- 列表使用 `.interactive` 键盘收起模式。

本页面在 `super.viewDidLoad()` 前关闭框架自动键盘安全区处理：

```swift
quickLayoutKeyboardSafeAreaBehavior = .disabled
```

`BottomObstructionCoordinator` 独占输入栏底部位移，避免框架键盘 inset 与页面 Sheet inset 重复抬升。系统键盘正常显示或交互下拉时，通过 `CADisplayLink` 读取 `UIKeyboardLayoutGuide.layoutFrame.minY`；照片 Sheet 展示时则读取呈现层的实时位置，让输入栏跟随上下移动，并以打开面板时最近一次完整系统键盘内容高度为上限。遮挡高度按“容器底部 − 遮挡顶部 − 容器底部安全区”计算，避免重复加入底部安全区。

照片 Sheet 提供键盘等高的小档（首次 300pt，最小 220pt）和 `.large()`。输入栏上限与 custom detent 均以不含底部安全区的键盘内容高度为依据，输入栏自身保留 8pt 页面内边距，Sheet 的悬浮边缘由系统负责。小档允许背景交互，大档使用系统遮罩。Sheet 超过键盘高度上限后继续覆盖下层内容，输入栏停在上限；向下收回时，输入栏恢复跟随。

键盘 → 照片时，输入栏在整个面板入场动画期间保持稳定键盘高度，不随面板从屏幕外升起而先下落再上移。系统入场完成后，以面板实际位置校准后续拖动的几何差值，消除悬浮边缘和缩放造成的小幅高度跳变；面板向下退出屏幕时，校准量也会归零。没有可见停靠键盘时直接打开照片，仍正常从底部跟随升起。从创建 Sheet 到明确切回键盘前，键盘通知不修改输入栏高度上限，也不触发 `invalidateDetents()`。附件菜单关闭时 UIKit 可能发出移除候选栏后的临时键盘高度；若用它覆盖上限，照片面板仍保持打开时的高度，就会遮挡输入栏。照片 → 键盘时先保留交接起点，收到键盘通知后按系统曲线切换到最终高度；Sheet 完全关闭且 keyboard layout guide 到达目标后才恢复逐帧键盘采样。交接期间不会在正在 dismiss 的 Sheet 上调用 `invalidateDetents()`。外接或浮动键盘没有底部软件键盘遮挡时，Sheet 消失后回到底部。

聊天页使用全屏时间线与底部悬浮输入栏的叠层布局。`UICollectionView` 始终填满页面，包括导航栏、输入栏和底部安全区后方；键盘与照片面板不改变列表 frame。仅输入栏消费侧边、底部安全区与额外遮挡高度。页面将列表注册为顶部内容滚动视图，让系统导航栏跟随时间线的滚动边缘状态。

列表关闭内容与滚动指示器的自动边距调整。`updateConversationViewport()` 根据安全区及输入栏实际 frame，统一更新可见区域与指示器边距。顶部、底部写入 content inset，左右安全区转换成消息 Section 的语义边距，收窄消息行而不扩大横向滚动范围。宽度或左右安全区变化会使布局失效，并清除旧横向偏移；RTL 使用对应的物理安全区边界。底部 inset 为列表底部到输入栏顶部的距离，原有分区上下 10pt 留白不重复加入。输入栏透明留白允许滚动触摸到达下方列表。

文本、录音、音频预览、媒体预览及遮挡高度变化统一由 `ConversationView.updateViewportInsets` 保持位置：变化前接近底部则继续跟随，否则按稳定时间线身份恢复相对可见区域的阅读锚点。首次历史仍在尺寸与边距稳定后才显示。附件预览只使用完整位于可见区域内的来源视图，被导航栏或输入栏遮挡时使用现有淡入淡出回退。

仅顶部导航栏展开或收起时，只同步顶部内容与指示器边距，不执行贴底或阅读锚点恢复；此规则也覆盖松手后的导航栏动画。否则程序化偏移会反过来驱动导航栏与安全区变化，导致下拉反复抖动。输入栏、底部遮挡、左右安全区及容器尺寸变化仍使用上述位置维护策略。

`ChatFullscreenLayoutTests` 覆盖空／短／长历史、遮挡高度、输入栏增高、实际窗口尺寸切换、左右不对称安全区、LTR／RTL 横向滚动范围、阅读锚点和透明边缘命中；`ChatFullscreenUITests` 已加入 `ChatRegression`，覆盖全屏 frame、左右拖动后消息位置不变、软件／外接键盘、返回及取消返回后的草稿继续编辑、横屏及深色 RTL 大字体。键盘是否可见按实际屏幕交集判断，不以 AX 节点存在代替。Duo 折叠屏或 iPad 窗口的旋转用例，仅在首页也不响应设备旋转时标记环境跳过；窗口尺寸切换仍由布局测试验证。

## Liquid Glass 与导航标题

输入栏继承 `QuickLayoutView`，使用 `QuickLayoutVisualEffectView` 承载玻璃内容。框架通过 `bodyContainerView` 把 QuickLayout body 安装到玻璃 API 要求的 `contentView`，控件布局由 `HStack`、`ZStack` 和 `onGeometryChange` 驱动。玻璃效果只用于输入控制层，不覆盖消息内容区域。“+”按钮的玻璃宿主通过 `UICornerConfiguration.capsule()` 固定交互形状，按钮配置同时使用 `.capsule`，因此普通态、按下态和菜单高亮态都保持 44 × 44 点正圆，不依赖系统临时推导圆角。

`ContactTitleView` 使用 QuickLayout 的 `HStack` 与 `VStack`，并通过明确的 `intrinsicContentSize` / `sizeThatFits(_:)` 桥接 `UINavigationBar` 测量。标题最大宽度为 220 点、高度不超过 44 点，包含 30 × 30 点系统头像、联系人名称 Alex 和本地化副标题。配置副标题后必须调用 `sizeToFit()`。

## 本地化、RTL 与辅助功能

- 文案位于 `Localizable.xcstrings`，权限说明位于 `InfoPlist.xcstrings`，均覆盖英语、简体中文和阿拉伯语。
- 文本统一使用自然对齐；收发位置只使用 semantic leading/trailing，不使用固定 left/right。
- 文本气泡、音频气泡、媒体组、播放、暂停、录音停止、删除、取消、发送、时长、播放进度、时间、送达状态、输入中状态和输入框均提供辅助功能标签或值。
- 多媒体组是 adjustable 元素：VoiceOver 递增查看下一项、递减查看上一项，播报“第 X 项，共 N 项，图片/视频”；到达首尾时播报边界且不循环。后置卡片不重复暴露为独立元素，双击从当前封面打开预览。
- Dynamic Type 会更新正文、时长与送达文本；固定单行的录音前提示字号最多为 20 点，并按宽度缩放，避免截断清空说明。系统语义色适配浅色、深色和高对比度。
- 输入中动画在 Reduce Motion 开启时停止；媒体操作不依赖装饰动画完成。

运行时切换语言会重建本地化固定文案与辅助功能文本，但不会修改音频附件、用户文本或语音转写后的草稿。运行时切换 LTR/RTL 会重建列表布局并刷新已物化 Cell，保证可见 Cell 与后续复用 Cell 使用同一方向。

## 路由与 Xcode Preview

页面通过 Demo 内部路由进入：

```swift
MainRoute.chat
```

每个独立 `UIView`、`UICollectionViewCell` 与 `UIViewController` 都在自身源文件末尾声明 `#Preview`，统一放在 `#if DEBUG` 内。方向敏感组件包含 RTL 变体；录音、预览、播放和 incoming/outgoing 音频气泡使用 `ConversationPreviewData` 的确定性数据。

预览数据只能来自 `ConversationPreviewData`。不要创建 `+Preview.swift` 文件或 `Previews` 目录，也不要在组件文件中临时构造会随时间变化的业务数据。

## 测试重点

聊天流程、音频与视图测试分别位于 `Demo/DemoTests/DemoTests+ChatFlow.swift`、`DemoTests+ChatAudio.swift` 和 `DemoTests+ChatViews.swift`，媒体测试位于 `Demo/DemoTests/ChatMediaTests.swift`；录音前提示和焦点分别由 `ChatRecordingHintTests.swift` 与 `ChatComposerFocusTests.swift` 验证。测试必须使用协议注入的假服务、固定 Clock、受控 Sleeper 与确定性附件，不能读取真实麦克风、依赖在线识别、调用真实系统声线或用真实休眠等待结果。

当前回归重点包括：

- 文本发送只生成文本回复；音频发送在最短准备时间和合成完成后生成音频回复，失败时回传同类型原语音。
- 回复合成的语言映射、取消、部分文件清理、时长和固定波形槽位保持确定。
- 音频 ID、时长、波形归一化和本地化刷新保持不变。
- 0.99 秒拒绝、1 秒允许和 120 秒自动停止边界。
- 录音、转写和播放互斥；切换条目、暂停续播、路由移除、无效文件与页面释放回到确定状态。
- iOS 26/旧版后端能力选择，以及英语、简体中文和阿拉伯语 locale 映射。
- partial result 替换、停止、错误、无结果和手动编辑不重复或覆盖原草稿。
- 空文本显示麦克风，非空文本显示发送；附件菜单包含“照片”、“音频”、“文件”和“链接”，非空草稿点击音频显示两秒清空提示，期间保留键盘焦点并拦截编辑，随后完整恢复。
- 1、2、5、20 项媒体发送边界，无效媒体原子拒绝，以及“媒体组 + 文字”按顺序分别回复。
- 选择顺序、草稿导入完成门槛、文件整体提交/清理，以及层叠状态跨 cell 重用保留。
- 5 项媒体的全部旋转顺序、物理左右滑方向、距离/速度阈值、首尾不循环和模型数组不变。
- iPhone 16 Pro 402pt 行宽下，三项媒体的 232 × 344pt 外框以及五项以上媒体的 248 × 356pt 外框完整参与 cell 首次自适应测量，不退化为 10 × 10pt 占位尺寸或与下一行重叠。
- 键盘与照片 Sheet 遮挡计算扣除底部安全区，避免输入栏顶部再出现一份重复安全区间距。
- 取消或发送音频后恢复原草稿，音频发送不清空文本草稿。
- 文本 1–5 行、录音/预览 64 点固定胶囊高度、16 点页面水平边距、键盘停靠与最后一条消息遮挡。
- Dynamic Type 变化会重新测量文本输入高度；固定 64 点媒体面板中的时长字体最多缩放到 24 点，保证辅助功能字号下时长完整且波形仍有可用宽度。
- 文本和音频 Cell 在 LTR/RTL 下贴正确语义边缘，并覆盖 Dynamic Type、VoiceOver、Reduce Motion、深色和高对比度状态。

编译、单元测试、Simulator UI、真实麦克风、真机 Speech、蓝牙/耳机和系统中断属于不同证据，验收时必须分别记录为“通过 / 失败 / 未执行 / 被环境阻塞 / 不适用”，不能用通用构建代替真机媒体结果。

## 维护约束

1. 模块保持 Demo 内部可见，不为 QuickLayoutKit 新增公开 API。
2. 不与现有 `ContentConfigurationModel`、`ContentConfigurationListViewModel` 或两种内容配置列表 Demo 合并。
3. 消息只存在于当前页面生命周期，不添加网络、上传或持久化抽象。
4. 新增时间线内容必须提供稳定 ID，并补齐 ListKit 刷新身份。
5. 录音、音频播放和实时语音输入必须继续由音频控制器单点拥有；音频和视频通过同一个页面级播放协调器互斥占用 `AVAudioSession`；消息文件转写由页面级串行队列拥有；附件文件由页面附件存储单点拥有，Cell 与输入栏不得直接创建媒体对象。
6. 修改气泡布局时必须同时验证短文本、长文本、音频、单媒体、多媒体层叠、LTR、RTL 和 Dynamic Type。
7. 修改输入栏时必须验证键盘展开、照片 Sheet 小/大档与交互拖动、两种遮挡源交接、1–5 行、录音态、媒体预览态、原草稿恢复和最后一条消息遮挡。
8. iOS 26 原生玻璃 API 只用于导航或输入控制层，消息内容层保持系统纯色背景。
9. Composer 预览项按 iPhone 16 Pro 参考图固定为 156 点高，按附件像素比例计算 80～208 点宽度，相邻项目间距 6 点；视频左下角显示白色摄像机图标，右下角显示时长，多帧图片和 Live Photo 左上角显示白底蓝色动态图片标志。删除按钮仍位于右上角，视觉直径 18 点、命中区域 44 点。当前范围不包含相机拍摄、图片编辑、视频剪辑、协作附件、上传、持久化、Tapback、内联回复或真实已读回执；GIF 在全屏预览中直接循环播放；Live Photo 保留配对资源并在全屏预览中长按播放。调试参数 `-imessage-save-fixture resources-draft -imessage-preview-draft` 可展示真实视频与模拟动态图片角标的混合草稿，仅用于 UI 验证。
10. Demo 应用支持 iOS 15，但聊天入口及依赖 iOS 26 API 的类型限定为 iOS 26；旧版语音识别后端只用于回退，不代表聊天页面支持旧系统。
11. 新增独立 View 或 ViewController 时，必须在同一源文件补充基于 `ConversationPreviewData` 的 `#Preview`。
12. 新增内部类型、状态、回调和用户动作方法使用 UIKit SDK 风格的 `///` 文档注释：先给出简洁摘要，再按需要补充讨论、参数和返回值；不要用逐行翻译代码的噪声注释。

## 参考资料

- [SpeechAnalyzer](https://developer.apple.com/documentation/Speech/SpeechAnalyzer)
- [Speech framework](https://developer.apple.com/documentation/speech/)
- [Apple Messages 使用说明](https://support.apple.com/en-gb/guide/iphone/iph82fb73ba3/26/ios/26)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [UIKit appearance customization](https://developer.apple.com/documentation/uikit/appearance-customization)

### 键盘与照片菜单 UI 回归

`ChatRegression` Scheme 运行 `ChatKeyboardUITests` 和 `ChatAudioCardUITests`，通过真实点击“输入框 → ＋ → 照片”验证切换前后输入栏底边保持一致且未被面板遮挡，并保留截图。已有草稿点击“＋ → 音频”另行验证两秒提示、原高度与键盘恢复，并保存中文及阿拉伯语 RTL 大字体截图。高度缓存与交接状态的确定性回归仍位于 `ChatMediaTests`。

### 多类型附件回归

- `ChatPasteTests`：真实剪贴板纯网址和混合媒体粘贴、按类型选择原始表示、UTF-16 选区与中文组合输入、异步乱序完成、启动前/加载中取消、导入失败、单项媒体分条发送、删除命中区域与 VoiceOver。
- `ChatDocumentTests`：附件顺序与批量原子拒绝、文件复制/提交/导入失败、迟到复制清理、无元数据链接、身份删除及失效撤销、失败保留后重试。
- `ChatAudioAttachmentTests`：真实录音取消、试听中的预览移交文件、录音转换位置与分段发送、媒体删除后继续保留、真实窗口键盘与中文组合输入、RTL 大字体排版及卡片删除后恢复高度。
- `ChatAudioCardUITests`：原生粘贴菜单、中文与 RTL 最大辅助功能字号下删除卡片及正文/焦点保留、照片面板内录音与预览转换、键盘删除卡片、链接与正文分条发送；系统照片库加载不完成时必须报告 UI 验证受阻。

2026-09-06 上一轮多类型粘贴验证记录（本轮位置与分段调整结果另行记录）：

- 构建：通过，最终 `Demo` 测试构建与 `ChatRegression` UI 测试构建成功，未新增框架公开 API。
- 测试：6 个 suite、59 项回归全部通过（包含 15 项粘贴测试），0 失败、0 跳过，结果为 `/private/tmp/IMessage-paste-all-pass.xcresult`。
- UI：中文原生粘贴与删除、RTL 最大辅助功能字号原生粘贴与删除、照片选择将录音预览转为附件并通过键盘删除、键盘到照片面板的高度衔接，共 4 条真实 UI 流程全部通过，0 失败、0 跳过，结果为 `/private/tmp/IMessage-paste-ui-verified.xcresult`。
- 视觉：检查原生粘贴后的网页卡片、RTL 大字体及删除后的高度恢复；真实窗口混合媒体截图覆盖图片缩略图、视频封面/播放标志/时长、音频和文档卡片及独立删除按钮。
- 验证边界：图片、视频、音频和文档使用真实生成文件经过原生粘贴及运行时导入测试，覆盖失败、取消和清理；尚未手动验收 iCloud/第三方文件提供器和真机。网页 UI 验证包含无远程元数据时的 URL 卡片。

### 按光标插入与按位置分段发送回归

- `ChatPasteTests`：16 项，覆盖真实混合剪贴板、UTF-16 选区替换、组合输入、连续粘贴、替换旧附件身份、乱序导入与失败清理。
- `ChatDocumentTests`：覆盖开头/中间/末尾插入、正文和多附件交错、有效段原始空白、纯空白段跳过、选区替换与失效撤销、菜单原选区恢复、原位置网址转换、整批发送拒绝。
- `ChatAudioAttachmentTests`：补充录音预览移交文件后，在同一选区紧接插入新内容的顺序验证。

2026-09-06 本轮验证（复用已启动的 iPhone 17 Pro / iOS 26.3.1）：

- 构建：通过，`Demo` 与 `ChatRegression` 测试构建成功。
- 回归测试：6 个 suite、66 项全部通过，0 失败、0 跳过；结果 `/private/tmp/IMessage-position-all-final.xcresult`。
- UI：5 条流程最终通过：中文原生粘贴与删除、RTL 最大辅助功能字号粘贴与删除、三段正文与两个附件交错发送、录音预览转文件后键盘删除、键盘切换照片面板。首轮 `/private/tmp/IMessage-position-ui.xcresult` 中 4 条通过；RTL 用例因长按落点未弹出编辑菜单失败，修正测试坐标后单独复验通过，结果 `/private/tmp/IMessage-position-ui-rtl.xcresult`。
- 视觉：检查交错草稿及发送顺序截图、RTL 大字体卡片和删除后的高度恢复；已发送卡片没有删除按钮，键盘焦点由用户操作保持。
- 验证边界：本轮为已启动模拟器的构建、运行时与真实 UI 自动化验证，未做真机及第三方文件提供器的手动验收。

### 收到附件的保存入口

收到的照片／视频组显示一个旁侧保存按钮，按原始文件一次保存整组到「照片」；音频文件及其他文件卡片导出副本到系统「文件」。发出的消息、波形语音、链接与文本不增加此按钮。成功后勾选显示 1 秒，再隐藏并保留布局占位；取消或失败恢复按钮。

`AttachmentSaveCoordinator` 按消息和附件身份管理当前页面的保存状态，`SystemAttachmentSaver` 负责 Photos 添加权限和系统文件导出。导出副本独立于页面附件目录，系统操作结束后清理；退出页面仅停止 UI 回调，不取消已经提交的系统操作。保存状态不跨页面持久化，不扫描相册，也不增加语音过期规则。

`ChatAttachmentSaveTests` 覆盖状态、截止时间、防重入、失败重试、整组原件保存、副本生命周期、窄屏／RTL 布局与 402 × 874 pt 截图。Debug 启动参数 `-imessage-save-fixture photo|group|audio|document` 在进入聊天时追加真实本地测试附件，用于手动验证系统授权和导出；`stack2|stack5|stack20` 追加不同颜色、带项目编号的媒体组，用于核对拖动换层及窗口顺序。正常启动使用下文的「首次历史加载与样例数据」，不追加此处的专用测试附件。

2026-09-09 保存入口验证：

- Demo 与测试目标编译通过；iPhone 16 Pro / iOS 26.5 上的保存、媒体和文档三组测试共 56 项通过，0 失败、0 跳过。结果：`/private/tmp/IMessage-AttachmentSave-Final56.xcresult`。
- 实际系统交互覆盖首次添加照片授权提示、拒绝及设置入口、授权后整组保存、音频文件导出取消后重试、PDF 导出后完成状态隐藏。
- 整组三张图片已写入模拟器相册，三份文件与原图字节一致；音频和 PDF 已保存到「我的 iPhone」，与原始文件字节一致，并分别在系统播放器和预览中打开。音频工具确认 16 kHz 单声道、1 秒、16000 有效帧。
- 曾发现系统先关闭文件选择器再交付成功回调，已移除按视图消失推断取消的逻辑，并通过可注入呈现入口加入回调顺序回归。
- 已检查 402 × 874 pt 浅色、深色 RTL 和大字号截图；窄屏和隐藏前后几何由测试验证。未做真机、iCloud／第三方文件提供器、真实视频／GIF 写入相册的手动验收。


## 统一液态玻璃附件预览

`AttachmentPreviewController` 统一已发送附件、文档草稿及照片草稿入口。
媒体采用黑色等比画布，顶部参考 iPhone 16 Pro 照片浏览器：44 pt 圆形玻璃返回按钮、严格居中的双行标题／数量胶囊、
44 pt 更多按钮。左右预留对称空间，长文件名截断，大字号增加胶囊高度，PDF／文本顶部避让同步更新。
更多菜单提供上一项、下一项与隐藏控件；边界项禁用对应导航，VoiceOver 开启时保留控件。多项媒体提供底部缩略图导航。
2026-09-13 顶部布局使用 Xcode 26.5、命令级 `DEVELOPER_DIR` 在 iPhone 16 Pro / iOS 26.5 构建与验证。
3 条 UI 流程通过：居中几何和 44 pt 按钮、菜单翻页与下拉转场、RTL／最大字号媒体及文档避让
（`/private/tmp/PreviewHeader16-ui.xcresult`）。截图检查后补充返回箭头镜像和数量文字适配，相关两条复验通过
（`/private/tmp/PreviewHeader16-final.xcresult`）。应用内语言切换的返回箭头按页面实际方向显式选择，
最终 RTL 截图复验通过（`/private/tmp/PreviewHeader16-rtl.xcresult`）；结果包保留截图，真机未验证。
玻璃控制层遵循 [Apple UIKit 设计说明](https://developer.apple.com/videos/play/wwdc2025/284/)，
使用 `UIGlassEffect` / `UIGlassContainerEffect`，透明区域不拦截内容手势。
底部缩略图条由 Demo 内部 `AttachmentThumbnailStripView` 提供，使用可复用 `UICollectionView` 和
`AttachmentThumbnailStripLayout` 自定义几何。普通项 20 × 30 pt、选中项 30 × 30 pt，普通间距 3 pt、
选中项两侧各 13 pt，圆角 2 pt、无描边。控件高 64 pt，有效交互带高 44 pt，左右各 12 pt 透明渐隐。
缩略图独立透明悬浮，播放控件才使用玻璃背景。首尾均可居中，附件按物理 LTR 排列。

`setPagingPosition(_:)` 接收主图连续进度，旧项收窄、新项展开和两侧留白同步插值，
固定 23 pt 逻辑步长避免尺寸变化反过来改变选中判断。`didSelectItem` 只请求翻页；正式状态由
`select(_:animated:)` 提交。缩略图拖动通过 `didBeginScrubbing` / `didScrubToItem` / `didEndScrubbing`
驱动即时切页，宿主回传不会改写拖动位置，停稳后吸附整数索引并只为最终项目准备播放器。
布局按可见范围计算，不构造全量属性或视图。

`MediaImageLoader` 在后台按屏幕像素降采样，最多两个并发任务、16 MiB 成本缓存；
复用和离屏时取消消费者，回写校验请求代次。控件随主图单击统一显隐，沉浸隐藏后取消加载且不拦截手势，
只记录最新进度，重新显示前恢复当前项；VoiceOver 开启时保持控制层可见。不新增 QuickLayoutKit 公共 API。

2026-09-14 胶片条改造验证：iPhone 18 Pro / iOS 27.0 编译通过，20 项预览、分页和胶片条单元测试通过；
其中千项用例使用不同项目 ID 和不同缩略图 URL，检查首次末项定位、宽度变化和可见 Cell／请求数量。
两条 UI 流程通过：原有翻页、旋转和下拉关闭，以及新增尺寸／间距、拖动浏览、沉浸隐藏后翻页再恢复。
截图导出位于 `/private/tmp/QuickLayoutThumbnailEvidence/ui-passed`。这些结果不代表真机帧率或峰值内存测量；真机未验证。

2026-09-13 控件抽取验证：Xcode 26.5 构建成功，iPhone 16 Pro / iOS 26.5 上 13 项单元测试通过
（`/private/tmp/ThumbnailStrip-unit.xcresult`），覆盖空数据、索引边界、末项首次露出、宽度变化、点击与提交状态分离及原有分页／预览回归。
两条 UI 回归通过（`/private/tmp/ThumbnailStrip-ui.xcresult`）：缩略图／菜单翻页、旋转、下拉取消与关闭、RTL 最大字号。
已检查结果包截图，导出位于 `/private/tmp/ThumbnailStrip-screenshots`；本次未做真机验证。

图片支持 1–4 倍捏合、双击缩放及单击控件显隐，分页和旋转保留当前项目。
分页使用 Demo 内部 `AttachmentPagingLayout`，直接继承 `UICollectionViewLayout`，由 ListKit 提供页面数据。
每页与视口等大，页间固定 20 pt，首尾不留间隔；关闭系统 `isPagingEnabled`，使用 `.fast` 减速和自定义目标吸附。
索引与坐标统一按“视口宽度 + 20”转换。慢拖以半页为界；速度绝对值达到 UIKit 回调的 0.35 且有至少 8 pt 同向位移时
翻向相邻页，快速反向回拖返回起始页，单次手势最多翻一页。普通滚动复用布局属性，尺寸或数量变化才更新几何。
拖动、减速和程序翻页结束统一校正精确位置并更新标题、缩略图及播放器；横向翻页期间暂停播放并禁止下拉关闭。
连续点击替换程序翻页目标，手势打断时从最近可见页接手。旋转保留程序目标或手势最近页；点击返回先停到最近可见页，再查询收回来源。

2026-09-13 自定义分页验证：通过命令级 `DEVELOPER_DIR` 使用 Xcode 26.5，在 iPhone 16 Pro / iOS 26.5 构建成功。
分页、附件预览和播放生命周期共 20 项单元测试通过（`/private/tmp/Paging20-unit-final.xcresult`），
覆盖 0／1／2／20 页、首尾边界、快慢拖动、反向回拖、动画替换与迟到回调、旋转及关闭时的当前附件。
5 条真实 UI 流程通过（`/private/tmp/Paging20-ui.xcresult`）：精确停页与边缘回弹、菜单／缩略图翻页和下拉转场、
图片缩放、RTL 最大字号、减少动态效果／降低透明度、视频进度与静音。结果包保留截图，另录制 `/private/tmp/Paging20-swipes.mov`。
首次验证遇到模拟器服务无响应和启动超时，恢复服务后完成上述回归；位置断言使用小于 0.001 pt 的浮点误差。
本轮未执行真机验证。

`AttachmentPreviewItem` 在后台按 UTType 分类。PDF 由 PDFKit 只读显示，文本由可选择的 UITextView 显示；
UTF-8 和带 BOM 的 UTF-16 文本最多读取 5 MiB。较大／无法解码的文本及其他格式由 Quick Look 兼容预览，
系统兼容预览保留原生工具栏；不存在、锁定或无法解码的内容显示本地化错误。

`AttachmentPreviewPlayer` 为视频和音频文件提供播放／暂停、时间、进度拖动与静音。
初次打开视频预览，在展开转场完成后自动播放当前视频；主图翻页或点击缩略图切换到新视频后，停稳时自动播放。
首次出现的启动机会只消费一次，取消关闭或返回页面不会覆盖用户的手动暂停状态。
连续拖动缩略图只展示中间项封面，松手停稳后仅播放最终视频；音频保留手动播放。
分页停止上一项，手动暂停后的布局、旋转及控件显隐不会重新启动当前视频；沉浸翻页自动播放也不显示控制层。
后台、音频中断及耳机断开暂停；关闭后清理 AVPlayer、观察者和音频会话。
音频和预览通过 `AudioSessionOperationQueue` 顺序执行会话配置、激活及停用，
避免旧停用回调影响新所有者。iOS 27 使用系统异步激活／停用 API；iOS 26 的同步调用在后台执行。
`AudioPreparation` 同样在后台准备录音器和音频播放器，避免准备过程内部同步激活会话阻塞主线程。
所有启动流程在等待后检查取消及请求代次，退出、暂停或切换媒体后不会因迟到回调重新录音或播放。
2026-09-14 自动播放验收：附件预览与音频生命周期 26 项单元测试通过，另补验旧翻页动画被打断后的自动播放场景。
iPhone 16 Pro / iOS 26.5 的主图翻页、缩略图切换、沉浸状态翻页与恢复共用一项 UI 回归，通过；
原生录屏八秒无操作区间内，中央游戏画面的半秒连续采样均有变化。录屏为
`/Users/sondra/.codex/visualizations/2026/09/14/01a09eda-4e04-7692-93f3-40b5edb1a130/video-playback/ios26-scroll-autoplay.mp4`。
本次自动播放改动未另行复验 iOS 27 或真机。
首次打开自动播放的追加验收：27 项附件预览与音频生命周期单元测试通过；
iOS 26.5 的“发送真实游戏视频 → 点击预览 → 不点击播放按钮”UI 用例通过。
原生录屏的无操作区间确认画面连续运动，录屏为同目录 `ios26-initial-autoplay.mp4`。
波形语音、网页打开方式及旁侧保存业务保持原入口。

`AttachmentPreviewTransition` 使用自定义 presentation、可中断 property animator 和百分比交互驱动。
卡片展开约 0.42 秒，收回约 0.34 秒；下拉超过视口的 22%，或位移超过 24pt 且向下速度超过 900pt/s 时完成关闭，
否则回弹。缩放、文档滚动／选择和控件拖动优先。来源通过消息／草稿 ID 延迟查询，离屏时淡出，不滚动聊天列表。
减少动态效果改用淡入淡出，降低透明度使用实色控制层，VoiceOver 模式保持控件可见。

调试样例沿用 `-imessage-save-fixture`，新增 `preview-text`、`preview-video`、`preview-rtf`、`preview-unavailable`。
与 `-imessage-preview-draft` 组合时，将已有媒体／文件样例放入输入栏，便于验证打开后原草稿和焦点恢复。
正常启动不注入样例。所有组件 `#Preview` 的固定资源仍来自 `ConversationPreviewData`。

验收包含 `ChatAttachmentPreviewTests`、更新后的 `ChatAudioLifecycleTests` 和
`ChatAttachmentPreviewUITests`；构建、单元回归、模拟器截图／录屏及真机证据分别记录。

2026-09-13 液态玻璃附件预览验证（Xcode 26.5 / iPhone 17 Pro / iOS 26.5）：

- 构建：命令级指定 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`；Demo 通用模拟器构建成功，Demo 与 ChatRegression 最新测试目标编译成功。
- 单元回归：附件预览、音频生命周期、媒体、文档、保存和输入框焦点共 6 个 suite、84 项通过，0 失败、0 跳过；结果 `/private/tmp/QuickLayoutPreview-unit-complete.xcresult`。包含 20 项媒体起始索引与尺寸变化、失效文件、迟到加载、来源离屏回退、关闭清理、后台暂停和播放互斥。
- 模拟器交互：10 条附件预览流程及 4 条现有键盘流程最终全部通过。覆盖消息与照片／文档草稿、1／2／20 项媒体、下拉完成与取消、当前封面同步、横竖屏切换、双击缩放、视频进度与静音、PDF 缩放滚动、文本上下滚动、Quick Look、错误状态和照片面板原档位恢复。
- UI 结果：主要记录 `/private/tmp/QuickLayoutPreview-ui-clean.xcresult`；其中视频进度用例暴露了 iOS 26 滑块在 touch-up 后继续发送 valueChanged 的顺序问题，修复后 `/private/tmp/QuickLayoutPreview-video-fixed.xcresult` 通过。旋转与文档手势补验 `/private/tmp/QuickLayoutPreview-gestures.xcresult` 两条通过；另外两条录音提示键盘回归在 `/private/tmp/QuickLayoutPreview-ui-final.xcresult` 中通过。
- 视觉与辅助功能：检查浅／深色、阿拉伯语 RTL、最大辅助功能字号；实际开启系统减少动态效果和降低透明度验证降级展示，结束后恢复开关及原浅色外观。中文、英文、阿拉伯语预览文案已校验。截图检查包含大字号文档首行避让、播放条和关闭入口；录屏覆盖展开、分页、下拉回弹与收回。
- 截图和转场录屏保存于 `/Users/chenchen/.codex/visualizations/2026/09/13/01a099e6-2f8b-75e2-a0f8-738889c2d6a0/attachment-preview/`；原始截图也保留在上述 xcresult 中。
- 真机验证：未执行；VoiceOver 已实现标签、控件常显、Escape 与返回来源焦点，但未执行真机朗读及完整手势遍历验收。

2026-09-13 媒体消息重叠修复：

- 真实 compositional 列表中，UIKit 的默认 Auto Layout 自适应路径把媒体 Cell 保留为 52pt 估算高度，而内部卡片仍绘制为 356pt，导致上下消息重叠。媒体 Cell 现在直接返回 QuickLayout 的内容测量结果，保留卡片原有尺寸。
- 新增真实窗口中的相邻发出／收到媒体消息回归；修复前复现两行均为 52pt 及内容越界，修复后通过。媒体、预览、保存三组共 56 项通过：`/private/tmp/MediaRows-fixed.xcresult`。
- 模拟器两条 UI 回归通过，检查打开前／返回后的媒体行包含完整卡片区域，并覆盖分页、旋转、下拉取消及完成关闭：`/private/tmp/MediaRows-ui.xcresult`。已检查截图中的相邻消息、数量标题和旁侧保存按钮位置。

2026-09-13 预览布局约定同步：

- 附件预览页面改用 `QuickLayoutHostingController`，玻璃标题、关闭按钮、播放条使用 `QuickLayoutVisualEffectView` 与 Stack 布局；缩略图使用自定义 `UICollectionViewLayout` 和可复用 Cell。附件分页由 `CollectionListAdapter` 管理，保留自定义分页布局和 delegate 转发处理全屏尺寸、旋转与播放绑定。
- 内容页改用 `QuickLayoutCollectionViewCell` 排布 PDF、文本、错误信息和加载状态；仅图片缩放居中及视频图层保留手动几何。分页的物理 LTR 与正文语义方向独立，避免从滚动容器覆盖阿拉伯语内容方向。
- 标题和文档顶部间距共用尺寸规则，避免嵌套布局时序导致大字号正文被标题遮挡。新增间距更新断言；预览及音频生命周期 16 项测试通过：`/private/tmp/Preview-QuickLayout-final-unit.xcresult`。
- 6 条相关 UI 流程最终通过，覆盖分页／旋转／交互转场、PDF／文本滚动、视频进度、草稿恢复、RTL 和最大字号。结果：`/private/tmp/Preview-QuickLayout-ui.xcresult`（其中大字号间距问题修正后复验）及 `/private/tmp/Preview-QuickLayout-final-ui.xcresult`（3 条复验通过）。已检查玻璃外形与大字号文档截图；本次未执行真机验证。

桌面 Resources 真实附件样例（2026-09-14）：

- 原件位于 `Demo/Resources/AttachmentPreviewResources.bundle`：21 张图片（含 GIF 和 HEIC）、6 段 MP4、1 个 PDF，总计 94,799,839 字节。原始文件逐字节复制；5 组重复宠物图片也保留为独立文件，便于验证相同内容的不同项目身份。忽略 `.DS_Store`。
- `manifest.json` 记录新文件名、桌面原文件名、类型、字节数与 SHA-256。Bundle 随 Demo 复制，因此会增加约 90.4 MiB 的未压缩资源体积；没有改写或压缩桌面原件。
- Xcode Scheme → Run → Arguments 增加 `-imessage-save-fixture resources`，进入「iMessage 风格聊天」即可打开 20 张真实图片的消息。视频使用 `resources-video`，PDF 使用 `resources-pdf`，新增 HEIC 使用 `resources-heic`；可叠加 `-imessage-preview-draft` 从输入栏预览。
- 样例仅在 Debug 且显式传入参数时注入；照片选择上限仍为 20。导入复用照片选择器的尺寸读取和封面生成路径，先复制到页面目录，再登记附件；退出时取消导入并回收临时文件。GIF 在草稿和消息卡片中使用静态封面，在全屏预览的当前页按原始帧时长自动循环播放。

- `IMG_7294.HEIC` 原样复制为 `preview-image-21.heic`，像素尺寸 4032 × 3024。当前资源目录没有配对 MOV，`resources-heic` 验证静态图像解码和单项预览；不能据此验收完整 Live Photo 动态播放。
- 真实资源验收：iPhone 18 Pro / iOS 27.0 模拟器构建成功；`testBundledResourcesPreview` 1 项测试通过（包含图片、HEIC、视频、PDF 四条路径），0 失败、0 跳过。验证选中宽度与中心误差 ≤ 0.5 pt、隐藏和恢复控件后中央主图像素一致、视频播放和跳转进度；已检查导出截图。真机性能与完整 Live Photo 动态播放未验证。
- 显隐回归直接对归档的同一张截图进行中央主图像素校验，覆盖隐藏与恢复两个状态，避免仅依赖控件存在性或采样截图与归档截图不一致。

2026-09-14 已发送视频连续画面回归：

- `testSentVideoActuallyRendersMovingFrames` 从真实视频草稿点击发送，再打开消息预览，依次播放 Resources 中全部 6 段游戏视频。
- 每段先等待播放时间达到 3 秒，再比较两个相隔至少 3 秒的中央主画面像素，排除仅封面切到第一帧造成的假通过；截图取样与归档使用同一对象。
- iPhone 16 Pro / iOS 26.5：1 项 UI 测试通过，覆盖 6 段视频，0 失败、0 跳过。iPhone 18 Pro / iOS 27.0 的第一段发送播放检查也通过。本轮增加回归验证，未修改播放器实现；先前报告的停帧原因尚未确定，用户在本轮运行中已确认画面恢复运动。

2026-09-14 视频无操作播放停帧修复：

- 复现：Resources 游戏视频发送后，从消息卡片展开预览，正常播放时进度前进但画面不变，拖动进度后更新一帧。之前的截图间像素差无法排除截图或 AX 查询触发刷新，不能作为无操作连续播放的证明。
- 触发点位于转场对整个 `AttachmentPreviewPage` 调用系统快照的路径，快照包含已绑定播放器的 `AVPlayerLayer`。同一模拟器、同一素材下，单独内容页及无动画打开的完整预览均正常；视频转场改为独立静态封面后，原发送／展开路径恢复连续输出。
- 新增 `transitionSnapshot(afterScreenUpdates:)`：视频仅复制封面 UIImage，缺少封面时淡入淡出；图片和文档保留原快照行为。视频展开和收回不会再对播放图层做系统快照，也不需要通过反复 seek 维持画面刷新。
- 同时移除每 0.2 秒进度回调中的播放器重新绑定，并按播放器身份过滤重复绑定；准备、更换页面和解除绑定仍走原生命周期。
- iPhone 18 Pro / iOS 27.0：真实视频发送、打开、播放、拖动后继续播放的 UI 用例通过；原生录屏检查正常播放十秒及跳转后六秒中的无操作区间，连续采样均有游戏画面变化。修改转场之前，同条件录屏在这两个区间停帧。录屏采集期间不截图、不查询 AX、不触碰进度条。
- iPhone 16 Pro / iOS 26.5：附件预览和音频生命周期 25 项单元测试通过，0 失败、0 跳过；包含静态转场封面、缺图回退、播放器绑定身份、页面回收、暂停取消及音视频互斥回归。
- iOS 26.5 最终版本另有 2 项 UI 测试通过，覆盖真实视频播放及跳转后继续播放、图片分页、下拉取消和完成关闭。原生录屏中正常播放与跳转后的无操作区间均有连续游戏画面输出；与 iOS 27 合计本次 3 项 UI 测试通过。
- 修复前后短录屏与验证记录保存在 `/Users/sondra/.codex/visualizations/2026/09/14/01a09eda-4e04-7692-93f3-40b5edb1a130/video-playback/`，分别为 `ios27-before-frozen.mp4`、`ios27-after-fixed.mp4` 和 `ios26-after-fixed.mp4`。
- `testSentVideoUninterruptedPlaybackForRecording` 输出两段无操作区间的时间标记；测试本身只断言状态和进度，连续画面仍需独立检查原生录屏。真机性能未验证。

2026-09-14 播放条常态与拖拽形态：

- 参考用户提供的 iPhone 16 Pro 照片应用截图：常态为 48 pt 单层清透玻璃播放条，仅显示播放／暂停、进度和静音；保留 iOS 26 `UISlider` 交互语义，按钮不再叠加玻璃圆底。
- 拖动开始后向上增加时间行，左侧显示 `mm:ss.SS`，右侧显示总时长；进度条横向展开并从 8 pt 加粗到 15 pt；`AttachmentPlaybackSlider` 自绘统一圆角的外轨道和无独立圆角的填充，保证进度分界竖直。常态和拖动共用同一个 UISlider，底边及进度条纵向位置固定；0.22 秒 ease-in-out 支持从当前动画状态反向收起，减少动态效果时直接布局。
- 拖动暂隐标题、返回、菜单、缩略图和状态栏，并关闭隐藏控件命中；不修改 `controlsVisible`。VoiceOver 开启时保留外围控制层。松手／取消恢复控件，播放状态沿用拖动前的状态；异步 seek 回调不驱动面板展开。
- iPhone 16 Pro / iOS 26.5：本轮构建通过；附件预览和音频生命周期 28 项测试通过，含拖动取消、主图几何及滑动控件身份保持；2 项 UI 测试通过，含真实游戏视频展开／拖动／收起、续播、暂停后拖动、静音。已检查原生录屏中常态、展开及恢复画面。
- 本轮形态过渡未在真机验证；iOS 27 和辅助功能大字号的该交互未单独运行视觉验收。正常、拖拽截图和过渡短录屏位于 `/Users/sondra/.codex/visualizations/2026/09/14/01a09eda-4e04-7692-93f3-40b5edb1a130/playback-controls/`。

2026-09-14 截图尺寸复核修正：

- 播放条宽度保持 346 pt（402 pt 视口下两侧各 28 pt）；常态高度 48 pt、圆角 24 pt；默认拖动高度 70 pt、圆角 26 pt。圆角值来自截图轮廓估算，通过同一次 UIKit 动画衔接。
- 时间行以底边定位，默认文字顶部约距面板顶部 19 pt、文字下方至轨道约 10–11 pt；大字号仍按字体行高扩展。缩略图外层仍高 64 pt，播放条与该容器间增加 4 pt，因此至图片可见顶部的间隔为 21 pt。
- 常态和展开态不替换触摸控件；整条轨道可起拖，按下不跳转，以起点窗口坐标和原轨道宽度计算相对位移，避免展开改变进度。保留取消、VoiceOver 调整和播放进度回调，图片大小及缩略图相邻间距不变。
- 本次尺寸修正后的最终验证：iPhone 16 Pro / iOS 26.5 构建及 28 项单元测试、2 项 UI 测试通过。展开时进度控件纵向中心保持测试通过；录屏确认两种形态、隐藏／恢复和直线填充分界。像素复核：常态外框 144 px、展开外框 210 px，轨道分别 24／45 px。真机、iOS 27 和 VoiceOver 实机操作未在本轮单独验收。
- 最终截图和过渡录屏：`/Users/sondra/.codex/visualizations/2026/09/14/01a09eda-4e04-7692-93f3-40b5edb1a130/playback-controls-fixed/`。

2026-09-14 预览控制层封装：

- `AttachmentPreviewController` 保留分页、播放准备、音频会话协调和转场，仅持有统一的 `chrome` 控制层；不再声明标题、位置、按钮、时间、滑块及玻璃容器等零散 UI 属性。
- `AttachmentPreviewControlsView` 管理整体布局、菜单入口、缩略图、透明区域命中、沉浸显隐与拖动时的联动动画，以弱引用回调传递用户意图。
- `AttachmentPreviewTitleView` 自行管理标题／位置标签、字号、截断、玻璃样式和尺寸测量。`AttachmentPlaybackControlsView` 自行创建播放／静音按钮、精确时间和 `AttachmentPlaybackSlider`，通过状态快照更新 UI，不持有播放器。
- 保留已校准的 48／70 pt 播放条高度、24／26 pt 圆角、8／15 pt 轨道、缩略图尺寸和间距；控制器与视图之间通过方法和回调通信，不保留旧 UI 属性的转发别名。
- 封装后验证：iPhone 16 Pro / iOS 26.5 构建通过；35 项单元测试通过，覆盖附件预览、音频生命周期及缩略图；3 项 UI 测试通过，覆盖播放条形变、隐藏控件后翻页自动播放、RTL 大字号文档避让。已检查普通播放、拖动及大字号文档截图；本轮未重新验收真机和 iOS 27。


### 媒体性能与原图边界

- 聊天页面拥有一个 `MediaImageLoader` 和 `MediaWorkScheduler`。导入处理、输入栏、
  消息卡片以及模态预览共享最多 2 项重处理预算；可见图片优先，完整原图最多 1 项。
  动态创建的 TextKit 卡片和列表视图通过响应者链获取页面服务，独立组件预览使用本地服务。
- 系统照片文件导入最多 2 项，排队前先登记全部占位。`MediaFileRequest` 在回调返回前
  复制系统临时文件；尚未复制时取消可以立即完成，复制中取消必须等待写入结束后清理。
  原件和缩略图只有在当前草稿版本仍有效时才交付页面附件存储。
- `MediaImportProcessor` 和图片解码入口显式使用 `@concurrent`，元数据、ImageIO 和
  JPEG 编码不在主 actor 执行。原件不转码，导入缩略图最长边 1280 像素、JPEG 质量 0.84。
- 普通显示位置只传入缩略图 URL，根据实际尺寸和屏幕 scale 后台下采样；缺少缩略图时
  不回退读取原图。同 URL、像素尺寸和裁剪模式共享请求，消费者独立取消。缓存精确按
  位图成本限制为 16 MiB，文件删除使缓存失效，内存警告和页面退出释放缓存。
- 只有预览器稳定的当前照片加载完整分辨率原件，取消旧的 3072 像素限制。
  加载时先显示缩略图，原图就绪保留缩放和视口；原图不缓存，离屏或退出即释放。
  翻页和缩略图拖动期间只显示封面，停稳后加载目标原件。同步解码不可中断时仍保留槽位
  直到真正返回，防止快速切页堆积大图任务。
- 多帧图片保持静态展示；Live Photo 保留配对照片和视频，支持全屏长按播放，其他视频原件播放、4 倍缩放和有序发送行为保持不变。
- Instruments 的 `com.quicklayout.demo / MediaPipeline` signpost 区分 `ProviderFileCopy`、
  `ImportMetadata`、`ThumbnailDecode` 和 `OriginalDecode`。性能对比应使用同一设备、
  同一 Release 配置和相同资源，分别测量冷缓存／热缓存；模拟器数据不能替代真机峰值内存。

`ChatMediaPipelineTests` 验证完整像素、方向与透明通道、缓存及请求合并、取消期间槽位持有、
可见工作优先、预览离屏释放，以及系统提供者乱序完成后的有序草稿和迟到文件清理。


#### 2026-09-15 验证

iPhone 18 Pro / iOS 27.0：99 项相关单元测试通过；预览 UI 17 项通过、1 项因系统设置入口
不可用而跳过，文件卡片相关 2 项复验通过。真实 HEIC 验证完整 4032 × 3024 像素。
同机 Release、相同测试运行器、每场景 3 次测量的平均峰值物理内存：20 项首次进入与预览
70.93 → 59.78 MB，热态重复预览 70.83 → 44.57 MB，完整 HEIC 预览 167.52 → 157.35 MB。
首次场景 CPU 时间略增，热态流程耗时基本持平；这些是模拟器本地夹具数据，不代表真机和
实际 iCloud 下载。卡顿指标未返回有效数值。详细方法、CPU／耗时及原始证据见
`/private/tmp/MediaPerformanceEvidence/report.md`。

#### 并发参数的独立验证

`2 / 2 / 1` 是项目当前配置，不是 Apple 规定的固定数字。`MediaBenchmark` scheme 和
`MEDIA_BENCHMARK` 编译条件提供重处理 1 / 2 的同构建对照，20 个文件型 provider 经过生产导入队列。
测试及数据完整性校验入口见 `Scripts/media-benchmark/README.md`。2026-09-15 的真机 XCTest
在开启自动化模式时超时，尚无完整配对证据，因此保持重处理默认 2；不得引用上一节整套优化的
模拟器数据来证明 2 优于 1。独立验证记录见 `Scripts/media-benchmark/results/2026-09-15.md`。


#### GIF 全屏预览

文件内容确认为多帧 GIF 后，当前页原图加载完成即通过 ImageIO 系统动画接口播放，无需点击或长按。
逐帧回填只更换图片像素，保留当前缩放、视口及沉浸状态；翻页、离屏和复用通过原图请求代次停止旧动画。
不预解码并持有整组帧，不显示普通视频控制条或实况入口。

#### 实况照片预览

系统照片提供者返回 `PHLivePhoto` 时，通过同一对象的 `PHAssetResource` 导出照片和配对视频。
导入优先级为实况对象、所选相册资源的原始实况配对、图片、视频。系统对循环等效果只提供 GIF 与 MOV 时，
请求相册读取授权（支持仅授权所选照片），通过 `PHAsset.mediaSubtypes` 确认实况身份后导出原始配对。
不依据资源标识或文件名猜测实况。未授权、所选资源不可访问或本来不是实况时保留图片表示，不伪造实况入口。
只有电影表示而没有图片表示时才进入普通视频导入。
两份资源及缩略图共同交付、登记和清理，取消后等待实际写入结束再释放导入槽位。
`MediaItem.livePhotoVideoURL` 保留配对视频，`isAnimatedImage` 仅表示图片自身多帧，GIF 不显示实况标识。
发送和模拟回复保留配对资源；保存先复制两份原件，随后在同一个相册创建请求中添加 `.photo` 与 `.pairedVideo`。

消息中的实况照片在每张照片卡片顶部前缘显示 18 pt 白色系统实况标志，内缩 12 pt，单张接收气泡额外避开尾部。
普通照片、GIF 和视频不显示该标志；卡片复用时同步更新，标志不截获照片手势，辅助功能将照片读为“实况照片”。
调试参数 `-imessage-save-fixture resources-live-single -imessage-preview-draft` 可验证单张实况的发送和模拟回复。

全屏预览左上角的实况玻璃胶囊包含“实况 / 循环播放 / 来回播放 / 关闭实况”菜单，状态只在本次预览内按项目保留。
标识随控制层进入沉浸模式时隐藏，不参与图片缩放。默认静态显示，长按使用 `PHLivePhotoView` 播放原声，
松手、翻页、关闭实况、关闭预览、失去前台或音频中断时停止；与现有音视频共用播放所有权和音频会话队列。
选择循环或来回立即静音连续播放原始配对视频；来回按真实帧倒序折返，切回实况恢复长按原声。
连续效果使用 AVAssetReader 顺序解码当前页的有界帧序列（通常 24 fps、最多 180 帧、约 48 MB 像素预算），
视频轨道的左上角坐标先转换为 Core Image 的左下角坐标，保持旋转和镜像方向与系统播放一致。
CADisplayLink 按原片段时长推进，只替换像素，不改变图片缩放几何。停止时取消解码并释放帧，迟到结果不能重启。
这些预览效果不写回照片，也不改变保存原件。长曝光不在当前菜单范围。失败保留静态照片，切换模式可重试。

`-imessage-save-fixture resources-live` 提供实况、普通图、GIF、另一份实况的混合消息；
追加 `-imessage-preview-draft` 则从草稿入口验证。测试资源由 `Scripts/make-live-photo-fixture.swift` 生成，
是原创 480 × 640、3 秒无声合成画面，具有匹配的照片标识和视频关键照片时间元数据。
它可验证系统重建和动态播放，不代表真实相册选择器、iCloud 下载或真机音频验证。


## 首次历史加载与样例数据

ChatViewModel 从空列表开始；正常新建 Chat 页面异步加载普通文本、富文本、图片、GIF、Live Photo、视频、语音、PDF 和链接的收发样例，共 38 条消息（收到、发出各 19 条）。Debug 和 Release 均启用。全部样例作为历史插入，不启动发送、回复、录音授权或自动播放；加载期间新增的消息保持原身份并排在历史之后。

`loadInitialHistory()` 负责页面首次历史加载，完成后通过 `insertInitialHistory(_:)` 批量插入，并发布 `.historyLoaded` 更新原因。ViewModel 接收独立的 `MessageHistoryEntry`，不依赖样例生成器的嵌套类型。当前临时数据来源为 `SampleChatHistory`；后续数据库接入属于数据来源的替换，不改变历史加载的更新语义。

`SampleChatHistory` 复用 `AttachmentPreviewResources.bundle` 的真实资源，生成页面独立副本和缩略图。收发附件使用独立身份并共享只读副本，退出页面统一清理。单项资源失败只跳过对应的一对样例，取消加载回收整个未完成批次。用户已经滚动或发送时，加载完成保留阅读锚点；否则滚动到最新消息。长历史中主动发送后，送达／已读刷新保留尚未完成的底部滚动，用户开始拖动则取消跟随。

样例富文本和链接标题按进入页面时的简体中文、英语或阿拉伯语生成；语音的中文转写忠实对应录音，不作为界面文案翻译。新增的 `default-message.caf` 是 5.35 秒的系统 Tingting 合成语音，原文为“你好，这是一条语音消息。点击播放，听听效果。”，时长与波形在导入时从真实 PCM 读取。可在 macOS 使用以下命令重新生成（运行时不合成语音）：

```sh
say -v Tingting -r 175 -o Demo/Demo/Resources/AttachmentPreviewResources.bundle/default-message.caf --file-format=caff --data-format=LEI16@22050 '你好，这是一条语音消息。点击播放，听听效果。'
```

注入 `ChatViewModel` 的页面入口从空会话开始。`-imessage-save-fixture`、`preview-video`、`-media-benchmark` 场景不追加完整样例；`-imessage-basic-history` 保留为跳过样例加载的兼容启动参数。专用附件 fixture 自身仍按原逻辑追加。

普通文本包含日常正文、电话、地址、网址、邮箱、日期时间、航班、快递单号、金额、物理单位，以及混合信息，共十一组收发样例。中文、英语、阿拉伯语文案在首次异步挂起前解析；日期采用相对时间，号码与单号用于演示格式，不代表真实联系人或包裹。正文使用只读 `UITextView`，显式启用电话、链接（含邮箱）、地址、日历事件、航班与快递检测，iOS 16 及以上再启用金额和物理单位；不使用 `.all` 或搜索建议。单击识别内容沿用 iOS 默认行为，长按统一显示消息菜单；识别结果和可用操作取决于系统、地区与服务可用性，未识别的内容保持普通文字，不增加正则或查询服务兜底。收到气泡使用系统链接色，发出气泡使用白色下划线。正文网址不会自动转成附件卡片，历史加载不会打开网页、地图、拨号或创建事件；发送及粘贴纯网址的既有链接卡片行为不变。

### 消息长按菜单

消息气泡通过 ListKit 的 `contextMenuForItems` 和 Row 的 `contextMenuPreview` 使用系统菜单。`MessageMenuPolicy` 按内容生成菜单，
`MessageMenuTarget` 在打开时锁定消息、附件和当前媒体项目的稳定身份；Controller 执行动作前再次校验。
多图／混合媒体的拷贝、存储和分享只处理当前封面，删除移除整条消息。发送失败时增加重新发送入口。

文字长按优先显示消息菜单，“选择文本”切换到原气泡中的系统选区；单击链接等系统识别内容仍保留原行为。
富文本拷贝同时提供纯文本与 RTF，GIF 使用原始动画数据。实况照片的“拷贝静态照片”只拷贝照片，
“存储实况照片”将配对资源写入相册，“分享原件”提供原始照片与视频两个文件，不承诺接收应用重建实况。
音频在已有转写时提供拷贝转写，音频和文件通过系统文件面板导出。

菜单存储允许两个收发方向，与收到消息旁的快捷保存按钮独立。导出和分享持有独立的
`AttachmentSaveSnapshot`，系统流程结束后清理副本。删除消息取消对应发送和模拟回复，
停止该消息音频播放，保持阅读锚点；共享的已提交原件仍由页面统一持有到退出。

测试入口：`ChatMessageMenuTests`、`ChatMessageDeletionTests`、`ChatMessageStatusTests` 和 `ChatMessageMenuUITests`。
UI 用例已加入 `ChatRegression`；`-imessage-menu-fixture` 仅在 Debug 中提供无发送任务的文字场景。

真实 Photos 写入用例默认跳过；显式设置 `TEST_RUNNER_CHAT_MENU_PHOTOS_WRITE=1` 后，
`testSaveCurrentLivePhotoAndGIFToPhotos` 会向所选设备相册新增两项测试资源（实况照片与 GIF）。

### 菜单原视图高亮

所有消息统一高亮原气泡或原附件卡片，参照 Apple `AddingContextMenusInYourApp` 的
`CollectionViewPreview` 示例。`previewProvider` 为 nil；高亮和收起时按稳定身份重新查询源视图，
保留气泡底色并使轮廓外透明，按实际气泡／卡片轮廓创建 `UITargetedPreview`，不包含整行空白、送达状态和保存按钮。
媒体组只突出当前最前卡片，切换动画期间不能发起菜单。正文选择期间也不发起消息菜单。
单张图片／视频沿用包含尾部的真实遮罩。预览动画以列表为目标容器，避免媒体堆叠的层级遮住收起快照。
文字与语音气泡在菜单开始时捕获当前显示画面，仅供收起动画使用；展开和菜单停留仍由真实气泡参与，
让系统隐藏来源，避免在预览下面露出第二份气泡。这样也避免 iOS 26 真机上真实气泡在系统
恢复来源前提前消失。收起阶段由 Row 的 dismissal 回调明确传入，不依赖它与 willEnd 的先后顺序。
源视图或尺寸改变时重新捕获，结束后释放；不创建内容控制器、不重新排版正文、不启动附件加载。

`MessageMenuCoordinator` 由列表持有，锁定消息、附件及媒体项目身份。菜单状态刷新保持同一目标；
菜单关闭动画完成后再次校验能力并执行操作。旧关闭回调不影响新菜单，源 Cell 复用或离屏后不返回
其他消息作为收起目标。系统动画期间只保留已显示的缩略图，结束后恢复正常的离屏释放。
Cell 的 `MessageMenuAccessibility` 仅管理 VoiceOver 操作，不安装单独的长按交互。
列表在 `collectionDelegate` 就绪后重新安装 adapter，使 UIKit 正确缓存并转发菜单关闭回调。

长按不加载网页、文件正文或媒体原件，也不启动视频／Live Photo 播放。正常点击附件继续打开完整
浏览器；链接交给系统浏览器。VoiceOver 的“打开预览”使用同一内容入口，不经过菜单播放交接。

`ChatMessageMenuPreviewTests` 验证真实 ListKit 菜单入口、命中范围、稳定身份、最新几何、生命周期及
辅助功能复用；`ChatMessageMenuUITests` 验证卡片高亮、收起、当前媒体项、普通点击打开和菜单操作。
`-imessage-menu-fixture -imessage-menu-web` 增加链接卡片；`-imessage-save-fixture resources-live-audio`
提供有声实况测试资源，用于验证长按不播放以及完整附件查看行为。
`-imessage-menu-fixture -imessage-menu-long-text` 提供屏幕边缘长文字，`-imessage-save-fixture audio-message`
提供语音气泡；叠加 `-imessage-menu-audio-transcript` 显示转写文本，用于检查整块气泡收起。
再叠加 `-imessage-menu-audio-outgoing` 可检查自己发出的蓝色语音气泡。
语音在波形内容区域长按展示菜单，播放按钮保留独立播放操作。

2026-09-22 ListKit 菜单迁移验证：

- 模拟器与真机 Debug 测试构建通过；未修改 ListKit、QuickLayoutKit 公共 API 或依赖锁定版本。
- 菜单／身份／删除／消息状态／完整查看共 40 项单元测试通过，媒体视图 56 项通过；合计 96 项、参数化展开 117 次执行，0 失败、0 跳过。
  结果：`/tmp/chat-listkit-unit-complete.xcresult`、`/tmp/chat-listkit-media-unit.xcresult`。
- iPhone 17 Pro / iOS 26.5 的菜单 UI 场景共 16 项最终通过，真实相册写入 1 项按默认开关跳过。
  整组运行中的语音用例最初按住了播放按钮；改在波形内容区域长按后复验通过。
  文字操作及几何修复后另行复验，结果：`/tmp/chat-listkit-iphone-verified.xcresult`、`/tmp/chat-listkit-media-complete.xcresult`。
- iPad 11-inch (M5) / iOS 26.5 完成长文字、语音、RTL 大字号、横屏媒体组、文字操作与当前项查看抽查。
  录屏发现媒体组收起曾露出后卡片；改用列表作为预览动画容器后复验通过，连续帧保存在 `/tmp/chat-fixed-motion-frames`。
- iPhone SE / iOS 26.6.1 六条菜单／完整查看 UI 回归通过；最终轮廓与收起修改后三条补验通过，
  结果：`/tmp/chat-listkit-device-final.xcresult`、`/tmp/chat-listkit-device-complete.xcresult`。
- 视觉验收采用代表场景截图及打开／收起录屏抽帧，未穷举全部设备、类型、字号和方向的组合。
  人工触觉、实际听音及完整 VoiceOver 手势验收未执行；辅助功能动作绑定与复用清理已有单元覆盖。

2026-09-22 文字连续收起补验：

- 用户录屏的「更早的消息 56」在约 1.47～2.37 秒整块不可见；iPhone SE / iOS 26.6.1
  对照录屏连续 8 次均出现约 0.9 秒空白。只检查菜单消失后的稳定截图不能发现这个问题。
- 最终实现只在文字收起时使用开始阶段捕获的显示快照，展开仍用真实气泡。
  真机历史富文本、短文字各 8 次开合逐帧检查没有空白，菜单稳定帧没有下层来源气泡重影。
- 真机 `ChatRegression` 三项 UI 回归通过，包括媒体组收起后打开第 2 项；
  iPhone 18 Pro / iOS 27.2 模拟器三项 UI 回归通过，包括长文字 8 次、键盘展开的新发送文字 8 次，
  以及复制、删除确认与选择文本。八项预览／稳定身份／生命周期单元测试通过。
- 最终结果：`/tmp/chat-outgoing-device-final.xcresult`、`/tmp/chat-outgoing-simulator-verified.xcresult`、
  `/tmp/chat-outgoing-unit-verified.xcresult`。本轮没有重跑 iPad、RTL、大字号全矩阵或人工触觉／音频验收。

2026-09-22 语音连续收起补验：

- 用户 15:07:51 录屏在约 2.62～3.50 秒丢失蓝色气泡、波形和转写，只剩播放三角形。
  收起显示快照由文字扩展到语音，展开仍使用真实来源，长按不触发播放。
- 模拟器与真机 Debug 测试构建通过。菜单单元测试 9 项、参数化执行 10 次全部通过，
  新增收到／发出语音的来源、快照、内容保留、连续会话及播放隔离检查。
- iPhone SE / iOS 26.6.1 真机三项 UI 回归通过：带转写的发出语音 8 次开合、收到语音长按不播放、
  发出文字 8 次开合。语音连续开合录屏的 694 个记录帧未出现气泡丢失，抽查稳定帧未见下层来源重影。
- iPhone 18 Pro / iOS 27.2 模拟器两项语音 UI 回归通过；抽查菜单稳定与首轮收起帧未见气泡空白或来源重影。
- 结果：`/tmp/chat-audio-unit.xcresult`、`/tmp/chat-audio-device-final.xcresult`、
  `/tmp/chat-audio-simulator-final.xcresult`。本轮未重跑 iPad、RTL、大字号全矩阵，未进行人工触觉或实际听音验收。
