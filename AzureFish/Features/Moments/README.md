# 朋友圈客户端

朋友圈采用与 Chat 一致的职责分层，使用 UIKit、QuickLayoutKit 和 ListKit。动态流与个人相册共享页面；网络、草稿及媒体业务继续复用 AzureFishAPI、AzureFishMoments 和账号加密存储。功能与运行证据见[设计说明](../../../Documentation/Design/Moments/README.md)和[验证记录](../../../Documentation/Design/Moments/validation.md)。

## 目录与职责

```text
Moments/
├── Controllers/       页面生命周期、导航、系统选择器、媒体编辑及播放
├── Models/            展示快照、分页状态和类型化交互事件
├── ViewModels/        动态流、发布草稿及评论的页面状态与操作
├── Views/
│   ├── Header/        相册封面与作者信息
│   ├── Feed/          ListKit 动态列表、动态内容与分页页脚
│   ├── Composer/      保留输入控件和焦点的发布组件
│   └── Preview/       图片缩放与分页 Cell
└── Support/           窗口运行时、媒体能力、图片绑定、缓存与预览数据
```

独立控制器按类型分文件；主文件保留属性、初始化和 UIKit 生命周期，跨文件实现按 `类型名+职责.swift` 命名。跨文件扩展需要的成员使用模块内部可见性，仅单文件使用的实现保持 private。保留 Moments 前缀以避免与同一应用模块内的 Chat 类型冲突。

组件的 `#Preview` 保留在源文件末尾的 DEBUG 条件内，统一使用 `MomentsPreviewData`。缩放、裁剪和下拉关闭沿用精确几何布局；普通页面与组件继续使用 QuickLayoutKit。

## 数据与交互边界

- `MomentsRuntime` 属于窗口，由 ChatRuntime 的账号停止屏障托管。业务数据、分页游标、待提交操作及账号资源只有这一份权威状态。读取刷新、草稿发布、互动、封面和媒体实现分别放在职责扩展中。
- `MomentsViewModel` 观察 Runtime 并生成只读 `MomentsFeedState`，管理当前页面的展开、操作中状态和续页请求。`MomentsFeedView` 管理 ListKit 行身份、系统外观、尺寸与阅读锚点；页面控制器处理导航、弹窗及跨窗口刷新。
- `MomentsComposerViewModel` 持有编辑草稿、防抖保存、提交冻结、错误和进度。发布失败从业务存储恢复同一草稿，未知结果复用原操作身份。`MomentsComposerView` 保留输入控件，不因语言或外观刷新覆盖同值输入；系统媒体导入与编辑租约由控制器协调。
- `MomentsCommentViewModel` 管理校验与评论重试身份，未知结果期间保持文本冻结。评论控制器负责输入控件和导航。
- 内容组件通过 `MomentsAction`、`MomentsComposerAction` 上报事件；通过 `MomentsMediaProvider` 获取头像和图片绑定能力，不直接调用 Runtime 的业务写入。

ViewModel 在 MainActor 上发布快照和回调，不持有 UIKit 控件或播放器。控制器保留原有 runtime 初始化入口，并支持注入 ViewModel。展示模型复用现有领域类型，不新增 Protobuf 或数据库结构。

## 资源与停止

列表与预览缓存保留现有账号、目标引用及资源版本身份。重复配置保留图片与加载任务；失权和账号停止同步撤回图片。Runtime 的任务登记、取消等待及加密存储规则保持不变。

发布页面结束时取消尚未触发的防抖保存、归还草稿占用并释放编辑文件租约；已登记业务任务仍受 Runtime 屏障管理。媒体结果和 ViewModel 回调校验账号运行代次，旧账号的迟到结果不能重新更新页面。页面尺寸与语言变化不重新创建 ViewModel 或草稿身份。

## 验证

单元与组件测试位于 `AzureFishTests/Moments`，UI 回归位于 `AzureFishUITests/Moments`。除既有分页、图片复用、草稿恢复和媒体测试外，页面状态测试覆盖防抖、提交冻结、评论重试与停止后的迟到结果。编译及预览不能代替实际列表和模拟器验证；本次结果单独记录在验证文档中。
