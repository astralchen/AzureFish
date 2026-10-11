# 朋友圈验证记录

本次 Chat 分层重构证据见文末独立章节；此前的首版及增量记录不计入本次验证结果。

日期：2026-10-11。范围：当前工作区客户端、独立服务端与协议；仅临时虚构账号环境。最低部署版本保持 iOS 15.0。

## 已执行

| 层级 | 结果 | 证据与边界 |
| --- | --- | --- |
| 协议／文档静态检查 | 通过 | 权威 proto 与客户端副本一致，`sync-server-protocol.py --check` 通过；50 个新增 Moments key 均有简中、繁中、英文、阿拉伯语；`git diff --check` 通过 |
| 服务端编译与全套测试 | 通过 | `AZUREFISH_RUN_HTTP_SMOKE=1 swift test --package-path AzureFishServer -j 4`；70 项中 66 通过、4 条件跳过，含真实 HTTP 冒烟；本机日志 `/tmp/azurefish-moments-server-final.log` |
| 客户端编译及 iPhone 测试 | 通过 | XcodeBuildMCP、AzureFish workspace/scheme、iOS 26.5 iPhone 17 Pro；首次完整朋友圈组合 9 项通过，包括 3 项 UI 测试 |
| iPad 及既有功能回归 | 通过 | iOS 26.5 iPad Pro 11-inch (M5)；36 项通过，涵盖朋友圈、账号共享存储、聊天徽标、统一导航、会话取消／退出／恢复 |
| 隔离真实网络联调 | 通过 | `MomentsLiveTests` 显式开启 `AZUREFISH_MOMENTS_LIVE=1`；原生 URLSession、客户端 SQLCipher／AES-GCM、真实回环服务和媒体工作进程；iPhone 与 iPad 均通过 |
| UI 自动化 | 通过 | 发现入口、动态流、作者相册与返回、九图列表、图片预览前后切换、英文浅色、阿拉伯语 RTL＋最大辅助字号＋深色 |
| 图片数量与宽度限制 | 通过 | 最终 iPhone 定向 8 项通过；同一内容视图反复切换 0～9 张、320／390／720／1,200 pt 容器、LTR／RTL；验证单图比例、4 张 2×2、其余最多三列及 320 pt 网格上限 |

服务端 4 个条件跳过项为原有投影性能用例、两个可选随机端口客户端用例及近 512 MiB 媒体用例；本次不把它们记为通过。

真实网络用例创建独立虚构账号，导入九张带数字的确定性 JPEG，反转图片顺序后发布，校验服务端原图摘要顺序；继续下载缩略图、重复同一点赞请求、评论／回复、删除评论、设置／恢复封面、删除动态并查询墓碑。服务端使用系统临时目录下的独立 `azurefish-moments-live-*` 目录及随机密钥，不读取仓库 `.local` 中的账号或服务数据。

## 关键覆盖

- 三个虚构账号验证共同好友互动过滤、不可见回复拒绝、成为好友后历史可见、非好友图片下载拒绝、拉黑后旧下载授权失败。
- 重复发布身份、不同正文冲突、点赞目标状态、旧点赞重放不反转新状态、已删除评论不能重插入、动态删除后原发布重放返回墓碑。
- 固定上界分页、新发布不混入旧游标、游标不可跨账号使用、媒体校验失败不提交动态；已登记首张图片后第二张失败时，媒体引用及幂等记录也回滚。
- 既有 `media_assets` 含聊天资源引用的升级保留数据和外键；账号删除清除动态、相册及相关互动。
- SQLCipher 旧账号库升级保留聊天草稿；独立朋友圈草稿重启恢复，原发布字节保留，错误密钥不能打开。
- 删除墓碑阻止旧版本复活；两个草稿共享图片时移除一个不能回收图片，最后引用移除后通过持久化回收队列清理。
- 模拟发布响应丢失，手动继续先查询原 ID，已成功时不再次提交；同账号窗口不能同时编辑同一草稿。
- 组件循环切换简中、繁中、阿拉伯语及英文（`en-US`），输入不丢失且 RTL → LTR 恢复；使用现有 AppLocalization，不另建管理器。

补充服务端定向回归：`swift test --package-path AzureFishServer -j 4 --filter Moments`，6 项通过（含媒体部分登记后的事务回滚），日志 `/tmp/azurefish-moments-server-targeted.log`。

## 最终修正复核

- iPad 导航及四语言组件：`test_sim_2026-10-11T02-46-56-040Z_pid20104_986596b9.xcresult` 中 3 项存储／组件、入口相册导航和阿拉伯语 UI 通过。九图用例遇到 XCUI 激活点错误，随后改为等待导航稳定并根据元素可见几何点击，保留进入预览、前后切图和返回断言。
- 九图用例复跑：`test_sim_2026-10-11T02-51-54-957Z_pid20104_f22fb3f0.xcresult`，1 项通过。最终截图来自修正后的实际模拟器。
- 本次修正还包括相册请求排队、前台权限复核覆盖图片预览、迟到图片下载的目标引用检查；对应代码已编译，真实网络用例在该轮通过。
- 图片布局补充后，`test_sim_2026-10-11T03-05-20-443Z_pid20104_94c53366.xcresult`：4 项存储／组件、4 项 UI，共 8 项通过。新增真实列表单图／四图几何断言，保留九图预览与四语言组件；布局组件额外覆盖竖图、极长横竖图及缺失尺寸的方形回退。
- iPad 图片布局复核：`test_sim_2026-10-11T03-09-41-586Z_pid20104_1de9cf43.xcresult`，单图／四图排布和九图预览共 2 项通过；人工截图确认宽容器内九图网格保持 320 pt 上限，四图不拉伸到正文栏宽度。

## 产物

本机测试结果（XcodeBuildMCP 目录，不属于仓库提交）：

- iPhone 9 项：`~/Library/Developer/XcodeBuildMCP/workspaces/AzureFish-f786ca84ece4/result-bundles/test_sim_2026-10-11T02-32-28-574Z_pid20104_9555220f.xcresult`
- iPad 36 项：`~/Library/Developer/XcodeBuildMCP/workspaces/AzureFish-f786ca84ece4/result-bundles/test_sim_2026-10-11T02-35-34-427Z_pid20104_9bdc83dc.xcresult`

人工视觉检查确认 iPad 导航标题／返回控件和缩略图填充已修正；其余人工辅助功能项仍按下表记录。

截图为 DEBUG 确定性展示夹具，数字色块用于识别图片顺序；网络联调由独立测试完成，截图中的离线提示不代表联调失败。

- [iPhone 九图列表](Screenshots/iphone-nine-images.png)
- [iPhone 单图比例](Screenshots/iphone-single-image.png)
- [iPhone 四图 2×2](Screenshots/iphone-four-images.png)
- [iPhone 阿拉伯语／大字体／深色](Screenshots/iphone-arabic-large-dark.png)
- [iPad 九图列表](Screenshots/ipad-nine-images.png)
- [iPad 四图宽度限制](Screenshots/ipad-four-images.png)

临时回环服务已停止，当前联调数据目录及密钥已清理；日志和测试产物保留。

## 未执行及环境限制

| 项目 | 状态 | 原因／后续验收 |
| --- | --- | --- |
| iOS 15～25 运行 | 被环境阻塞 | 仅安装 iOS 26.5 模拟器；部署目标和 availability 编译检查不能代替旧系统运行 |
| iOS 27.1／Duo 专用 API | 被环境阻塞 | 当前 SDK／模拟器不提供该路径；未臆造 API 或提高最低版本 |
| 真机、生产部署与真实账号 | 未执行 | 本轮范围限定虚构账号隔离环境 |
| VoiceOver 实际朗读、降低透明度、增强对比度 | 未执行 | 已提供系统语义颜色和无障碍标识，仍需人工设备验收 |
| 多窗口拖动、旋转、系统相册选择／排序／裁剪的完整人工流程 | 未执行 | 已覆盖独立草稿身份、尺寸布局与图片业务闭环；自动化片段不能替代全流程人工验收 |
| 故障注入完整矩阵 | 未执行 | 已覆盖发布丢响应、错误密钥和共享回收；部分上传断网、进程强杀、所有媒体篡改／跨账号替换／备份场景仍需专项补测 |

## 全屏预览增量验收

本轮仅调整客户端预览，协议、服务端及数据库不变。自定义分页使用现有 `AttachmentPagingLayout`，页宽随容器变化、页间距为 20 pt。

- 首轮 iPhone：`test_sim_2026-10-11T04-04-04-491Z_pid20104_103e717d.xcresult`，10 项通过（4 项原有聊天分页、4 项朋友圈图片组件、2 项真实 UI 手势）。覆盖左右拖动、缩放锁定、单击显隐、下拉关闭及返回后的列表位置。
- 组件验证当前页／相邻页加载窗口、失败重试、取消后的迟到响应、Cell 复用、缩放中心、失权清理及窗口重排。
- iPhone 补充：`test_sim_2026-10-11T04-15-46-612Z_pid20104_5e8dc803.xcresult`，7 项通过（4 项组件、3 项 UI）；新增拖动中旋转定位、实际横竖屏页码保持、短下拉取消、单图边界、四图中间页打开及阿拉伯语物理翻页顺序与末页边界。
- 首轮工具等待超过 300 秒后，核对后台构建与日志，最终出现 `TEST EXECUTE SUCCEEDED`；超时本身不计为通过。
- iPad 最终复核：`test_sim_2026-10-11T04-25-14-236Z_pid20104_3ecf89dd.xcresult`，同样 3 项 UI 全部通过。使用上轮测试产物，未重复构建；日志最终为 `TEST EXECUTE SUCCEEDED`。
- [iPhone 黑底全屏预览](Screenshots/iphone-fullscreen-preview.png)、[iPad 黑底全屏预览](Screenshots/ipad-fullscreen-preview.png)。人工检查确认系统关闭按钮、页码和等比居中的图片；数字色块仍为测试图片。
- iOS 15～25、Duo／iOS 27.1、真机和 VoiceOver 实际朗读仍未执行；已有编译及自动化不能替代这些运行验收。

## 列表图片闪烁与缓存增量验收

- 列表以可见状态比较决定是否提交快照，并按行比较内容、展开／提交状态和布局环境。图片和封面独立比较账号、资源及引用目标，重复配置保留图片与任务；新 Cell 同步读取最多 36 张／32 MiB 的内存缩略图缓存。异步解密期间不插入默认图片图标；默认封面仅表示尚未设置封面。
- iPad：`test_sim_2026-10-11T04-41-33-760Z_pid20104_4889b72b.xcresult`，4 项组件加 1 项 UI，共 5 项通过。组件检查相同图片对象同步复用、互动／尺寸更新、缓存命中首帧、封面替换／恢复默认、缓存容量／资源版本／目标／账号隔离，以及账号停止时清空缓存和复用视图。UI 实际打开并收起菜单、进入预览并返回，验证阅读位置。
- iPhone：`test_sim_2026-10-11T04-46-52-034Z_pid20104_5b09795c.xcresult`，复用同一测试产物，4 项存储／布局、1 项发布响应丢失恢复及 1 项菜单／预览返回 UI，共 6 项通过。
- 本轮通过 iOS 15 部署目标的模拟器编译；运行环境为 iOS 26.5。旧系统、Duo、真机、VoiceOver 朗读和真实服务联调未执行；协议、服务端与数据库结构未改动。组件的同步图片身份断言与 UI 返回流程分别验证，不用静态截图替代瞬时闪烁检查。

## 预览缓存与放大后翻页增量验收

- 原图使用账号内的 9 张／96 MiB 缓存；命中时同步显示，只有缩略图时先显示缩略图并继续读取原图。当前及相邻页按需启动请求，已启动请求跨页复用。关闭后重新打开可复用原图；内存警告、容量淘汰及失权清理分别处理。明确收到动态失权错误时移除本地动态及其展示，普通下载失败保留缩略图和重试入口。
- 放大后在图片内部拖动查看，到达左右边缘后再次向外横滑即可翻页。内外层手势分别判断边界，不建立等待已禁用内层手势的固定失败关系；捏合与下拉关闭仍互斥。原图替换缩略图保留缩放比例和查看中心。
- 初次实际 UI 回归发现固定失败关系阻挡了普通分页，已移除。iPad 修正后结果 `test_sim_2026-10-11T05-22-21-353Z_pid20104_d41f648d.xcresult`：九图普通分页和保持放大后的边缘翻页共 2 项 UI 通过；该轮另有 1 项组件失败，定位为空状态 Cell 复用残留动态无障碍标识，随后修正所有非动态行的标识与交互状态。
- 最终 iPhone：`test_sim_2026-10-11T05-29-32-450Z_pid20104_3647b8c1.xcresult`，13 项组件加 1 项实际 UI，共 14 项通过。组件覆盖同步缓存命中、返回已加载页／进行中请求计数、重新打开、失败保留缩略图及重试、缓存范围／版本／淘汰／内存警告、退出清理、升级原图时缩放中心，以及放大图片边缘和方向判断；UI 在不缩回的情况下翻至下一页，并完成下拉关闭。
- 编译与 `git diff --check` 通过。工具等待超时后以后台日志中的 `TEST EXECUTE SUCCEEDED` 和测试明细确认结果；未把超时计为通过。最新构建已安装到 iPad 比较页。独立人工逐帧视觉、旧系统、Duo、真机、VoiceOver 实际朗读及真实服务联调未执行；协议与数据库结构未变更。

## 列表全屏增量验收（2026-10-11）

- 朋友圈及个人相册移除 collectionView 的 720 pt 宽度限制，铺满当前页面，滚动内容由系统自动调整安全区域；照片尺寸上限不变。
- 编译、4 项 `MomentsRenderingTests`、iPad Pro 11-inch (M5) / iPadOS 26.5 的 2 条 UI 流程通过。覆盖 1,200 pt 容器的完整页面几何、图片复用、实际窗口宽度、相册导航、单图比例与四图网格上限。结果包：`test_sim_2026-10-11T06-27-49-384Z_pid20104_01968788.xcresult`。工具等待超时后，后台日志确认 `TEST EXECUTE SUCCEEDED`。
- 已打开并检查 [iPad 全宽对比页面](Screenshots/ipad-fullwidth-feed.jpg)，封面及动态行延伸至页面两侧，图片保留尺寸限制。iPhone、其他系统、真机、VoiceOver、RTL 与窗口连续缩放本轮未执行；协议、数据库及服务联调不适用。

## 自动续页与轻量页脚验收（2026-10-11）

- 改为接近底部自动续页，覆盖减速和短列表自动填充；底部转轮、失败重试及结束短线使用独立复用池，分页错误不插入顶部状态行，失败保留游标并停止自动重试。续页不再重复请求相册封面；无进展游标被拒绝，避免连续请求同一页。
- 最终编译与 7 项组件测试通过：页脚居中和状态切换、图片／封面复用、短列表在真实窗口中自动续页、请求去重、失败后点击页脚重试同一游标、停止加载及退出清理。iPad 结果：`test_sim_2026-10-11T06-52-26-637Z_pid20104_0bd66595.xcresult`，另含 1 条覆盖加载／失败／结束三状态的 UI 流程。
- iPhone 17 Pro / iOS 26.5 复用同一构建，三状态 UI 流程通过，已检查 [iPhone 重试页脚](Screenshots/iphone-pagination-retry.png)：`test_sim_2026-10-11T06-59-06-009Z_pid20104_73dc3803.xcresult`。iPad Pro 11-inch (M5) / iPadOS 26.5 截图已检查：[加载](Screenshots/ipad-pagination-loading.png)、[失败重试](Screenshots/ipad-pagination-retry.png)、[结束](Screenshots/ipad-pagination-ended.png)。这些是 Debug 状态夹具，顶部离线提示与注入的分页展示状态独立；真实分页与重试由组件测试的隔离传输覆盖。
- 中间验证发现并修复页脚缺少布局失效通知；本地化属性补充 MainActor 标注。UI 自动化按稳定标识查找状态文本／按钮，避免将辅助功能类型变化误判为缺失 Cell。最终成功以实际后台日志和结果包确认，工具超时不作为通过依据。
- 四语言资源格式和 `git diff --check` 通过。真机、旧系统、Duo、实际 VoiceOver 朗读、四语言逐项界面、大字体及真实服务端联调本轮未执行；无协议或数据库变更。

## 复跑

页脚视觉夹具使用 `-moments-ui-test -moments-photo-count 0 -moments-pagination-state loading`；状态可替换为 `failed` 或 `ended`。此开关仅在 Debug 生效，不访问网络。

手动比较图片排布可用 Debug 启动参数 `-moments-layout-demo`，直接打开同一朋友圈列表中的单图、四图和九图样例；数字色块为确定性测试图片，可点击进入预览。此入口不访问服务端，也不创建真实动态。

先以随机密钥、独立临时目录启动虚构账号回环服务，显式设置 `AZUREFISH_MEDIA_WORKER` 为已构建工作进程绝对路径。测试中的真实网络用例默认关闭。

XcodeBuildMCP 先核对 session defaults；设置 AzureFish workspace/scheme、目标模拟器及复用 DerivedData。`test_sim` 传 `testRunnerEnv: {"AZUREFISH_MOMENTS_LIVE":"1"}`，选择 `MomentsStorageTests`、`MomentsRuntimeTests`、`MomentsLiveTests` 与 `MomentsUITests`；其他导航、徽标、会话用例按本表选择。结束后停止临时服务，保留必要日志并清理临时虚构数据。

## 视频发布与播放（2026-10-11）

本节只记录本轮视频扩展，不用上文历史结果替代视频验证。范围包含相册选择／拍摄入口、系统裁剪、最高 1080p MP4 导出、加密草稿、单视频发布、权限、封面及全屏播放；媒体与图片互斥，最长 60 秒。

| 验证层级 | 结果 | 本轮证据 |
| --- | --- | --- |
| 协议与文档 | 通过 | 权威 proto 生成后同步客户端副本，`sync-server-protocol.py --check`、`git diff --check` 通过；朋友圈代码引用的 66 个现有／新增文案键均有四语言 |
| 服务端编译／完整测试 | 通过，条件用例跳过 | `swift test -j 4` 枚举 71 项，66 通过、5 条件跳过；`/tmp/moments-video-server-mp4.log`。新增用例现场将虚构 MOV 导出为真实 MP4，经 HTTP 分块上传、处理和发布，覆盖三账号访问、拉黑后的原件／封面授权、混排拒绝、0／60000／60001 ms 发布边界、事务回滚、重放及删除墓碑 |
| 客户端编译／组件 | 通过 | 12 项：旧草稿／动态兼容、导出与加密草稿恢复、租约释放、视频封面缓存与宽度限制，以及既有图文存储和复用；iPad 结果包见下文 |
| iPad 模拟器／隔离联调 | 通过 | iPadOS 26.5，14 项（上述 12 项、1 项真实回环联调、1 项 UI）。联调保留九图、互动和封面回归，并新增视频导出、真实发布、两次下载租约、删除与失效读取 |
| iPhone 模拟器 UI | 通过 | iOS 26.5，视频播放／返回缓存封面用例，重复打开两次，等待播放器就绪，检查关闭控件位置及阅读锚点 |
| 人工视觉 | 通过（指定样例） | 检查 iPhone／iPad 浅色列表封面、播放图标、时长及宽度上限；全屏黑底、原比例视频与右上关闭。截图使用仓库自带虚构测试素材 |
| 真机、旧系统与专项辅助功能 | 未执行／环境缺失 | 系统裁剪实际交互（模拟器返回不可编辑）、真机拍摄与麦克风、真实相册／iCloud 导入、长视频手动选择裁剪范围、iOS 15～25、Duo 专用 SDK、四语言完整视频流程、VoiceOver 朗读、深色／大字体／动态窗口缩放专项未执行；最低部署仍为 iOS 15 |

- iPad 最终结果：`test_sim_2026-10-11T07-47-53-348Z_pid20104_14b9e75b.xcresult`。
- iPhone 播放最终结果：`test_sim_2026-10-11T07-50-27-717Z_pid20104_62166f04.xcresult`；该轮只实际执行 1 项，不把命令中指定但未运行的裁剪用例计入。
- 结果包位于本机 `~/Library/Developer/XcodeBuildMCP/workspaces/AzureFish-f786ca84ece4/result-bundles/`。
- [iPhone 视频封面](Screenshots/iphone-video-poster.png)、[iPhone 全屏播放](Screenshots/iphone-video-playback.png)、[iPad 视频封面](Screenshots/ipad-video-poster.png)、[iPad 全屏播放](Screenshots/ipad-video-playback.png)。

本轮联调发现并修复媒体工作文件扩展名过滤错误：原规则把 `.mp4` 截成 `.mp`，导致 AVFoundation 处理失败；现保留 ASCII 数字，并由真实 MP4 上传回归覆盖。中间轮次的测试导入遗漏、演示目录未创建和 MP4 处理失败均不记为通过，以上结果来自修正后运行。系统裁剪器不公开起点，选段由加密导出文件保存，不宣称恢复系统裁剪滑块的位置。服务端 5 项条件跳过为投影性能、两项随机端口客户端、近 512 MiB 媒体和原有 socket 冒烟；朋友圈自身的真实 HTTP 上传和 iPad 客户端回环联调已执行。

裁剪 UI 验证纠正：`07-56-57` 结果虽然显示 1 项通过，但截图显示仍在发布页，原断言误匹配发布页的“取消”，该结果作废。已改为必须找到系统裁剪器容器，再操作其取消控件；不可编辑时明确报告环境限制并验证原草稿保留。Apple 说明 [canEditVideo(atPath:)](https://developer.apple.com/documentation/uikit/uivideoeditorcontroller/caneditvideo(atpath:)) 受设备硬件和媒体格式限制；不绕过此检查强行呈现系统组件。

最终增量编译：`08-02-58` 日志确认 `TEST BUILD SUCCEEDED`，包含相机临时文件清理、编辑器不可用提示、视频草稿封面及独立时长布局。联调完成后已停止本轮独立服务并删除临时虚构账号数据和随机密钥；保留结果包与截图。

裁剪专项最终结果：`test_sim_2026-10-11T08-02-58-735Z_pid20104_c97f62c1.xcresult`，0 通过、0 失败、1 环境跳过。进入不可编辑分支后已断言明确提示、视频草稿存在和发布按钮可用；系统裁剪器的取消／保存交互仍需支持该能力的真机验证，不记为通过。

## 视频关闭按钮重复修复（2026-10-11）

播放就绪后隐藏页面附加的关闭按钮，只使用 AVKit 原生关闭控件；加载／失败时保留页面退出入口，并隐藏尚不可用的播放控件。避免右上额外关闭按钮遮挡系统静音控件。未修改协议、服务端或数据库。

- iPhone 实际截图确认只剩左上系统关闭按钮：[单一关闭控件](Screenshots/iphone-video-single-close.png)。
- 第一轮 iPad 测试在用例开始前 Runner 启动崩溃（`09-12-49`），不计为通过；已重启模拟器。
- 第一轮 iPhone（`09-23-10`）通过按钮唯一性断言并截取上述画面，但截图期间原生播放控件自动隐藏，后续自动化点击失败。回归改为先暂停再截图与关闭，不改变应用的自动隐藏行为。

- iPhone 最终回归通过：`test_sim_2026-10-11T09-25-29-355Z_pid20104_85c16ead.xcresult`，1 项 UI、0 失败；两次进入播放器，检查附加关闭按钮不存在、原生关闭只有一个、实际关闭成功及原动态阅读位置保持。后台日志确认 `TEST BUILD SUCCEEDED` 和 `TEST EXECUTE SUCCEEDED`。

- iPad 本轮最终状态为环境阻塞：重启后 `09-32-27` 复跑仍未进入测试用例，约 202 秒后停止此次测试进程，工具记录 `BUILD INTERRUPTED`（复用测试产物的执行阶段，非编译错误），不计通过。截图工具同时曾报 `Timeout waiting for screen surfaces`。
- 编译、`git diff --check`、iPhone iOS 26.5 UI 与指定样例人工视觉通过；加载／失败退出入口经代码核对，本轮未单独注入网络失败 UI。真机、旧系统、Duo、VoiceOver 朗读及其他外观专项未执行；协议／数据库／服务联调不适用。修复版已在 iPhone 模拟器重新打开视频示例。


## Chat 分层重构（2026-10-11）

范围：朋友圈客户端目录、ViewModel、类型化事件与视图组件拆分；共享业务包、服务端、协议和数据库结构未在本次调整。保留工作区已有修改。Xcode 26.5（17F42），复用 `/tmp/AzureFish-operation-DD`。

| 层级 | 结果 | 本次证据与边界 |
| --- | --- | --- |
| 文档与静态检查 | 通过 | 模块／设计说明链接可解析；新文件无行末空白；`git diff --check` 通过；Runtime 原入口均保留，ViewModel 不导入 UIKit |
| 应用及测试编译 | 通过 | `AzureFish.xcworkspace` / `AzureFish`，iOS 26.5 Simulator，`CODE_SIGNING_ALLOWED=NO`；日志 `/tmp/azurefish-moments-refactor/build.log` |
| 单元／组件回归 | 通过 | 最终 iPhone 17 Pro 上 29 项通过、0 失败、0 跳过；涵盖页面状态、Runtime、存储、渲染、照片和视频 |
| 强化迟到结果断言 | 通过 | 最终 5 项 ViewModel 测试再次通过；确认异步操作确实已经开始，再停止账号并放行迟到结果 |
| iPhone UI | 通过（含条件跳过） | 10 项中 9 通过、1 跳过、0 失败；系统视频裁剪器 `canEditVideo` 为 false，保留草稿的回退检查通过；照片预览、分页、导航和视频播放通过 |
| iPad UI | 通过 | iPad Pro 11-inch (M5)，iOS 26.5；最终六项通过、0 失败，覆盖 RTL、大字体、菜单返回、分页、缩放／下拉关闭、单图／四图及视频播放 |
| iPhone 分页最终复验 | 通过 | 最终代码再次通过分页页脚加载／失败／结束三种状态，0 失败 |
| 四语言与方向切换 | 通过 | 组件测试切换 zh-Hans、zh-Hant、ar、en-US，验证未提交正文保留和 RTL → LTR 恢复；不等于完整四语言人工视觉验收 |
| iOS 15～25 / 27.1 Duo | 被环境阻塞 | 当前仅安装 iOS 26.5 模拟器运行时；最低部署版本仍为 iOS 15 |
| 真机、真实服务、录音／相册写入 | 未执行 | 未开启真实联调和硬件测试开关；本次不采用历史服务端或联调结果替代 |
| VoiceOver、降低透明度、增强对比度人工验收 | 未执行 | 保留原有控件与无障碍标识；自动化及编译不替代系统辅助功能人工验收 |

单元／组件结果位于 `~/Library/Developer/XcodeBuildMCP/workspaces/AzureFish-f786ca84ece4/result-bundles/`：

- `test_sim_2026-10-11T09-59-52-504Z_pid73549_6b72928e.xcresult`：28 项回归。
- `test_sim_2026-10-11T10-03-25-813Z_pid73549_5cad05b3.xcresult`：5 项强化断言后的 ViewModel 回归。

新增 6 项 ViewModel 用例覆盖防抖合并及旧快照丢弃、提交后冻结、评论未知结果重试身份、重复提交拦截、账号停止后的迟到响应。既有 Runtime 测试通过新 ViewModel 驱动发布丢响应后的对账重试，并检查动态操作失败后解除忙碌状态。列表测试继续在真实 ListKit 列表中验证自适应尺寸、图片复用与失权撤回。


iPhone UI 工具等待超过 300 秒，但后台测试继续运行；最终日志与结果包确认 `TEST EXECUTE SUCCEEDED`（10 项、1 条件跳过、0 失败，约 458 秒），不以工具超时推断测试状态。结果包：`test_sim_2026-10-11T10-04-43-983Z_pid73549_45ab03b8.xcresult`，与上述单元结果位于同一目录。

已逐张检查本次 iPhone [英文浅色](Screenshots/refactor-iphone-light.png)和[阿拉伯语大字体深色](Screenshots/refactor-iphone-arabic-dark.png)截图；列表宽度、混合文本换行和图片顺序符合当前布局。截图不代替 VoiceOver 或其他未执行的人工验收。


复验发现并修正了自动续页的一个副作用：运行时未就绪时，续页检查不应结束顶部刷新，否则短列表可能反复触发布局。新增 `unavailablePaginationDoesNotChangeTopRefresh` 回归。首轮 iPad 运行主动中止，不计入最终通过数；修复后重新构建并完整运行 29 项单元／组件测试，全部通过。最终结果包：`test_sim_2026-10-11T10-16-58-841Z_pid73549_1725a1be.xcresult`。该轮工具等待超时发生在构建／启动阶段，后台最终日志明确记录 29 项通过及 `TEST EXECUTE SUCCEEDED`。


最终 UI 结果：

- `/tmp/azurefish-moments-refactor/iphone-pagination-final.xcresult`：iPhone 分页复验通过，1 项、0 失败。
- `/tmp/azurefish-moments-refactor/ipad-ui-final.xcresult`：iPad 最终六项通过，0 失败、0 跳过；对应完整日志为同目录的 `ipad-ui-final.log`。
- 已检查本次 iPad [四图宽屏](Screenshots/refactor-ipad-four-images.png)与[阿拉伯语大字体深色](Screenshots/refactor-ipad-arabic-dark.png)截图；列表铺满容器，多图尺寸上限和 2×2 布局保持，RTL 文本及图片内容可读。

人工视觉检查限上述 iPhone／iPad 截图；未执行项和环境阻塞项保持表中状态，不扩大为完整设备矩阵验收。
