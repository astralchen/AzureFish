# Repository Guidelines

## 项目结构与模块组织

AzureFish 是基于 Swift 6/UIKit 的应用，最低支持 iOS 15。完整聊天功能要求 iOS 26+；旧系统使用 `AzureFish/App/LegacyChatViewController.swift` 兼容入口。消息流程目前采用本地模拟实现。

- `AzureFish/App/`：本地化、系统兼容与 Debug 测试入口。
- `AzureFish/Features/Chat/`：按职责划分为 `Controllers`、`Models`、`ViewModels`、`Views`、`Animations` 和 `Support`。
- `AzureFish/Support/Concurrency/`：共享异步工具。
- `AzureFish/Assets.xcassets`、`AzureFish/Resources/`、`AzureFish/*.xcstrings`：图像资源、媒体测试素材与本地化文案。
- `AzureFishTests/Chat/`、`AzureFishUITests/Chat/`：单元、组件与 UI 测试。
- `Scripts/media-benchmark/`：性能测试工具；`CHAT_MIGRATION.md`：AzureFish 迁移验证记录。聊天模块 README 中的历史结果属于来源工程。
- `Documentation/`：数据库、认证、安全、多设备 UI／UX 与国际化设计及验收文档。

## 工程边界与设计文档

AzureFish 负责客户端界面、交互、网络调用与本地数据；仓库根目录 `AzureFishServer/` 是独立 Swift 服务端，负责用户身份、权威资料及后续 IM。两端数据库不共享文件。网络采用 HTTP＋Apple SwiftProtobuf，未来实时 IM 使用 WebSocket；传输安全遵循下文。服务端是网络契约的唯一来源，客户端仅同步其 `.proto` 副本及注释，不独立维护契约；AzureFishProtocol 通过官方 SwiftProtobufPlugin 在构建时生成 Swift 类型，不提交客户端生成代码，确保无需服务端目录也能独立构建。

- [数据库设计](Documentation/Database/README.md)：本地业务结构、同步、生命周期与迁移。
- [认证接入](Documentation/Authentication/README.md)：客户端职责、服务端文档及权威网络契约入口。
- [数据安全](Documentation/Security/README.md)：加密、密钥、缓存、退出与恢复规则。
- [多设备 UI／UX](Documentation/Design/README.md)：布局、系统外观、深浅色与状态连续性。
- [四语言国际化](Documentation/Internationalization/README.md)：资源、语言偏好、格式化与 RTL。

上述文档当前标注“设计阶段，尚未接入应用”。认证、加密存储、主题选择和繁体中文不得描述为已经实现；登录成功也不代表真实 IM 已接入。实施时核对当前代码，完成后同步更新设计状态与验证证据。调整契约或生命周期规则时同步引用文档，避免出现两套决策。

任务明确为文档阶段时，仅修改约定文档，不自动创建 Swift、`.proto`、SQL、数据库、启动脚本或安装依赖；后续代码工作按用户指定范围实施。

## 构建、测试与开发命令

完整聊天功能开发需要配备 iOS 26+ SDK 和模拟器的 Xcode。在仓库根目录执行：

```sh
open AzureFish.xcworkspace
xcodebuild -workspace AzureFish.xcworkspace -scheme AzureFish \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/AzureFish-DD CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -workspace AzureFish.xcworkspace -scheme AzureFish \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' \
  -derivedDataPath /tmp/AzureFish-DD CODE_SIGNING_ALLOWED=NO \
  -only-testing:AzureFishTests test-without-building
```

以上命令依次打开 Xcode、编译应用及测试、运行单元与组件测试。将 `<SIMULATOR_UUID>` 替换为已安装模拟器的 UUID。本地运行选择 `AzureFish` scheme；专项 UI 回归使用 `ChatRegression`，性能测试使用 `MediaBenchmark`。首次构建需要联网解析并下载 Swift Package 依赖。

## 代码风格与命名约定

使用四空格缩进，类型采用 `UpperCamelCase`，成员采用 `lowerCamelCase`。文件名与主要类型一致；扩展按 `Type+Responsibility.swift` 拆分。保留 Actor 隔离和 API 可用性检查，文档注释遵循下文规范。

仓库目前未配置代码格式化或静态风格检查工具。本地化规则见下文。

## 代码注释与 API 文档

参考 UIKit SDK 的描述方式，以调用者需要理解的行为和使用契约组织注释。使用中文 `///` 与 Swift DocC 支持的格式，保留 API 名称、参数名和技术术语；不照搬 Objective-C 头文件语法，也不逐行翻译实现。

- 首句用简洁、完整的句子概括职责：类型说明代表或管理的对象，属性说明其含义，方法说明执行的操作或返回的结果。避免“用于处理相关逻辑”“执行初始化”等空泛描述，以及仅重复名称的注释。
- 按需在空行后补充调用条件、可观察的副作用和边界行为。属性说明默认值、有效范围、`nil` 的含义及修改后何时生效；集合说明空值、顺序或重复元素规则。只描述实际存在且影响使用的契约，不机械套用所有栏目。
- 有必要解释的参数、返回值和错误使用 `- Parameter`／`- Parameters`、`- Returns:`、`- Throws:`；参数名与签名一致，说明业务语义、单位和约束，不重复类型信息。没有返回值或不会抛错时不添加对应栏目。
- 生命周期与重写点说明谁调用、何时调用、是否可能重复、可执行的工作，以及必要的 `super` 调用或调用顺序。UIKit 行为以当前 SDK 声明为准，不将项目实现习惯写成系统保证。
- 异步操作、代理与闭包说明实际执行上下文、触发条件、调用次数、取消与失败语义；涉及持有关系时说明资源所有者和释放时机。`@MainActor`、`@available` 等由代码声明约束，注释不能替代或扩大这些保证。
- 布局与几何 API 明确坐标空间、单位、安全区域／内容 inset 的处理及生效时机；涉及失效标记与立即更新时，说明区别，避免将“请求更新”描述为“已完成布局”。
- 声明上的 `///` 说明使用契约；实现内部的 `//` 解释非显然的原因、算法限制或兼容处理。简单私有实现无需逐项补注释，不记录临时调试过程、修改流水账或与当前行为不符的历史说明。
- 修改行为时同步修订相关注释；纯注释任务保持签名与逻辑不变。不得编造线程安全、回调必达、性能、可用版本或数据持久性保证，未验证的设计目标留在设计文档中。

## 数据安全

以下为后续实现必须遵守的设计约束，详细格式与恢复流程以安全文档为准：

- 正常业务使用 HTTPS，未来 IM 使用 WSS，保持证书链、主机名与有效期验证；禁止关闭 TLS 校验或在发布配置中全局放宽 ATS。Debug 回环 HTTP 仅用于隔离的虚构测试数据；真实账号、Apple 登录及真机联调使用 HTTPS。Protobuf 只负责序列化，不提供加密，不另造网络加密协议。
- 本地业务库采用 GRDB＋SQLCipher，每环境、每账号独立随机密钥；消息、草稿、资料、任务和搜索索引同库加密。媒体、头像及持久缓存使用独立密钥的 AES-GCM 认证加密，并绑定账号、资源和用途。系统文件保护继续保留。
- 数据库和媒体密钥分别保存在 Keychain 的 `AfterFirstUnlockThisDeviceOnly` 项；会话凭据与存储密钥分开管理。禁止使用密码、用户 ID 或固定字符串充当密钥，禁止将密钥、token、密码及敏感正文写入仓库或日志。
- 禁止 URLCache、缩略图或资料快照绕过加密存储。系统组件必需的临时明文使用受保护、按账号隔离且排除备份的目录，具有访问期限、使用结束清理及启动时遗留清理机制。
- 普通退出清除会话凭据与明文内存，保留加密数据和存储密钥；显式清除本地数据或确认账号删除后，按停止任务、结束访问、清理文件与备份、删除对应密钥的顺序处理。缺失或错误密钥时停止打开原库，不静默生成新密钥覆盖或重建空库。
- 承载真实账号前先验证 SQLCipher／GRDB 的 iOS 15、FTS、迁移、备份和链接兼容性；不得因集成失败退回明文存储。服务端敏感字段与文件加密不等于 Fluent SQLite 整库加密，也不等于 IM 端到端加密。

## UI 布局与预览

新增或调整 UI 时，优先采用 **QuickLayoutKit 布局 + `#Preview` 预览**，参考 `AzureFish/Features/Chat/` 的现有实现。

- 页面与组件优先使用 `QuickLayoutHostingController`、`QuickLayoutView`，通过 `HStack`、`VStack`、`ZStack` 描述层级、尺寸、间距和对齐；集合内容配合 ListKit 的 `CollectionListAdapter` 管理。
- 新增独立 View、Cell 或 ViewController 时，在同一源文件末尾的 `#if DEBUG` 内提供 `#Preview`，按实际 API 标注可用版本。使用确定性样例覆盖关键状态，按需补充长文本、大字体和 RTL 预览；Chat 模块统一复用 `ConversationPreviewData`，不另建 `+Preview.swift` 或 `Previews` 目录。
- 当 QuickLayoutKit 无法满足具体布局、系统集成或性能需求时，再局部采用 Auto Layout、手动 frame 或其他方案，并简要说明原因。图片缩放、`AVPlayerLayer`、遮罩、手势和自定义转场等精确几何场景可使用手动布局。
- `#Preview` 用于快速检查组件效果；自适应 Cell 还需在真实列表中验证尺寸与复用，页面交互需通过模拟器或真机验证。

## 多设备、系统外观与主题

- 覆盖 iPhone、iPad 和 iPhone Duo；依据当前窗口／内容容器尺寸、size class、安全区域与 reserved regions 布局，不按设备名称、固定屏幕分辨率或启动时缓存宽度分支。局部遮挡不一律转换为整页额外边距，弹出层锚定实际触发控件及其 windowScene。
- **iOS／iPadOS 15～25 使用原生非液态玻璃外观，不仿制 Liquid Glass；26 及以上优先使用系统 Liquid Glass 导航与控件。** iPhone Duo 的 iOS 27.1 增强适配沿用液态玻璃体系；专用 API 以实际 SDK 声明为准设置准确 availability，不能进入旧系统路径或提高全应用最低版本。
- 主题提供“跟随系统、浅色、深色”，默认跟随系统。本机偏好键为 `azurefish.appearance.preference`，值为 `system`、`light`、`dark`，缺失或无效值回退 `system`。欢迎页外观菜单和“我 → 应用设置 → 外观”共享偏好，勾选表示用户选择而非当前解析出的颜色。
- 启动及新增窗口在首帧前恢复主题，所有窗口共享偏好策略；`system` 随各窗口系统环境解析，手动选择保持指定外观。退出、切账号或清除某账号数据不重置主题，不新增服务端主题同步接口。
- 使用系统语义颜色，检查图标、品牌、默认头像及加载／错误／禁用状态的深浅色辨识度；错误不只依赖颜色。用户照片与媒体保持原样，不简单反色。遵循“降低透明度”“增强对比度”；系统授权、相册和权限界面遵循平台支持的呈现行为。
- 尺寸、内外屏、主题或语言转换保留页面、导航选择、表单、焦点、阅读锚点和上传状态，不因外观变化重建业务会话、返回首页或重复提交。窄屏与宽屏共享业务状态，首个可见帧即应正确。

## 四语言国际化

目标语言为简体中文 `zh-Hans`、繁体中文 `zh-Hant`、英文 `en`、阿拉伯语 `ar`。当前代码及 String Catalog 已有简中、英文和阿拉伯语，繁中仍待接入；后续新增或修改用户文案按四语言要求交付。

- 沿用 AppLocalization、现有场景本地化协调机制和 String Catalog，不建立第二套语言管理器。语言提供跟随系统与四种手动选项，不支持的系统语言回退英文；沿用 `azurefish.locale.identifier`，保留已有偏好兼容性。
- 语言偏好属于当前安装，与主题独立，退出和切账号不重置，不新增服务端语言同步接口。切换保留未提交输入与业务状态，并验证 RTL → LTR 恢复。
- 覆盖页面、校验、业务错误、权限说明、删除确认、空状态及无障碍文案。使用完整句子、类型明确的占位参数、复数规则及 locale-aware 日期／数量／文件大小格式化，不拼接句子或按中文长度固定布局。繁体独立翻译，不采用运行时简繁替换。
- 使用 leading／trailing 与语义方向，避免重复镜像；技术标识及混合文本保持可读，照片、视频及无方向含义的图标不镜像。用户内容、用户 ID、账号规范化、密码规则及协议值不随显示语言改变。
- 服务端返回稳定错误码和字段标识，由客户端本地化；系统 Apple 授权、相册等界面的语言遵循平台边界，不承诺被应用内语言强制切换。

## 测试规范

单元与组件测试使用 Swift Testing（`@Test`、`#expect`），UI 流程使用 XCTest/XCUIAutomation。聊天测试类型遵循 `Chat<Feature>Tests`、`Chat<Feature>UITests` 命名，其他模块按对应业务命名；XCTest 方法以 `test` 开头。针对行为变更补充回归测试；当前未配置覆盖率数值门槛。真实录音、语音识别和 Photos 写入测试需显式开启对应测试开关。

- 根据变更范围选择验证，分别报告文档检查、编译、单元／组件测试、模拟器 UI、人工视觉、真机及真实服务联调，标明“通过／失败／未执行／被环境阻塞／不适用”。预览、编译及文档静态检查不能代替运行验证，历史或来源工程结果不能充当本次结果。
- UI 验收覆盖 iOS 26 以下非液态玻璃、iOS 26+ 液态玻璃、iOS 27.1 Duo 增强路径，以及 iPhone／iPad 尺寸变化、深浅色、四语言、RTL、大字体、VoiceOver、降低透明度与增强对比度；检查首帧、焦点、导航与业务状态连续性。
- 安全实现验证缺失／错误密钥、篡改和跨账号替换、轮换中断、恢复、临时明文清理、日志及备份；详细输入与证据要求见[安全与跨设备验收](Documentation/Security/validation.md)。
- 仅文档变更检查链接、字段／规则一致性、Markdown 格式及 `git diff --check`，不将应用编译、模拟器或真机项目标记为已通过。

## Commit 与 Pull Request 规范

Git 提交标题和正文使用中文，专业术语、代码标识符与文件路径保留原文。标题简短明确，以“新增”“修复”“调整”“移除”等动词说明变更，例如 `移除主 storyboard 引用`、`修复聊天草稿恢复异常`。每次提交聚焦单一主题。PR 应说明行为变化、关联相关 Issue、列出验证结果与限制；涉及 UI 的变更应附截图。保留工作区中无关的修改，并审查依赖锁文件的变更。
