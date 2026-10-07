# 分阶段修复与本次验证

日期：2026-10-06。范围：用户批准的四阶段修复；保持 iOS 15 最低部署、现有数据、协议和依赖版本。环境为 Intel macOS、Xcode / iOS 26.5 SDK 与已安装模拟器。本文件只记录本轮证据，历史结果不替代当前测试。

## 代码实施

| 阶段 | 行为与边界 |
| --- | --- |
| 正确性与生命周期 | 新旧页面共用 ChatTimelineWindow，分批最多 200 条查询、保留已加载最早序号；刷新纳入新消息及撤回，搜索上下文与已加载窗口分离。同步和传输使用任务身份／代次，停止先取消再等待，取消不发布失败。运行时更新循环只在当前迭代持有所有者，最终释放归还账号存储。 |
| 导入补偿 | 追加 chat-media-import-v1，不更改既有基线；写文件前登记身份，草稿／展示／混合发送引用与批次完成同事务提交。失败、取消及首次账号打开恢复，仅回收全部业务均无引用的资源。 |
| 工程复现 | 协议来源版本取相关输入最近提交，保留 hash、SwiftProtobuf 检查。三个 UI 依赖固定现有 revision。Release 排除测试 bundle；MediaBenchmark 保留 Release 优化及测试素材，Debug 保留夹具。 |
| 客户端性能 | 列表使用服务端尺寸、类型和 thumbnail／cover，不要求本地原件。原件在预览／播放／导出前解析。下载按环境、账号和资源跨窗口合并，各调用方独立授权／取消。URLSession 按块接收并逐块检查上限；状态和进度通知按业务范围刷新。 |
| 服务端性能 | 同账号实时连接共享补偿查询，事务提交后提示；会话鉴权和心跳保留。未读可选版本投影在原事务维护，旧数据有界回填；成员资料批量获取、单次解密。 |

回归过程中额外修正了临时租约重复清理、账号目录已移除时的释放、输入暂停期间格式操作，以及列表安全区域和迟到滚动回调。滚动判断区分向上阅读和自适应高度／内容缩短造成的系统偏移补偿，保留音频转写增高时的底部跟随。沿用既有组件测试验证这些行为。

没有改动网络字段、加密算法或生产 TLS／ATS 策略，没有升级依赖或清空业务数据。普通会话读取不再扫描未读历史；水位写事务仍对当前可见未读密文执行认证，以保留已有密文替换检测。这一检查保留了安全语义，也限制了水位写入的性能提升。

## 本次验证

| 验证项 | 本轮结果与证据 |
| --- | --- |
| 客户端包 | 通过：AzureFishChat 43 项（12 个 suite）、Storage 6 项、Network 32 项、API 35 项。覆盖 350 条时间线、旧库升级、导入补偿、立即重启、迟到回调、独立取消及网络限制。 |
| 服务端包 | 通过：64 项（18 个 suite），包含未读扫描对照、安全／事务回滚、共享 WebSocket 和凭据失效。 |
| 客户端实时联调 | 通过：独立 AzureFishAPI WebSocket 测试 1 项；临时服务、随机回环端口、虚构账号。 |
| 协议与工程静态检查 | 通过：来源校验 2 项、协议内容／版本检查、pbxproj 语法检查；依赖锁文件未变。 |
| 应用编译 | 通过：Debug 应用与单元／UI 测试目标、Release 应用（Intel 模拟器，最低部署 15.0）。Debug 用模拟器临时签名运行；Release 主模块实际包含 -O 与 whole-module optimization。MediaBenchmark 应用及 UI 测试目标构建通过，应用和主要 Swift Package 实际包含 -O 与 whole-module optimization；应用具有 MEDIA_BENCHMARK DEBUG 条件，包依赖没有这些条件。 |
| 模拟器单元／组件 | 未达到全量通过：最终全量尝试在系统 UIPasteboard.items 阻塞，主线程采样已确认；重启模拟器后仍阻塞。排除 ChatPasteTests 16 项与真实音频播放 1 项后，执行 413 项／51 个 suite，其中 412 项通过，附件删除动画末帧断言失败；该项单独复核 1 项通过。新增远程媒体／运行时释放、350 条分页、阅读位置及音频增高贴底均通过。真实音频播放单独复核仍失败，同期有 HAL 音频设备错误；不能将本轮全量回归标为通过。 |
| 模拟器 UI | 首轮 8 项中 7 项通过，录音流程在等待停止控件时失败。核对发现原用例未设置显式录音开关，现补充 CHAT_AUDIO_RECORDING=1，默认跳过；不以跳过替代原失败记录。纯媒体 RTL 用例首次因测试辅助方法查找不存在的首页搜索栏失败，改用实际回归路由标识后通过；录音用例默认开关关闭时按预期跳过。本轮 iPhone 共 8 项非录音场景通过；iPad 首次 Instruments 连接等待，重启后 3 项（媒体堆叠返回、RTL 大字体、混合草稿恢复／预览／发送）全部通过。主机同期有内存压缩／换页，UI 耗时不作为性能证据。 |
| 配置包 | Debug 包含测试素材 113,633,363 字节（108.4 MiB）；Release 应用包确认没有 AttachmentPreviewResources.bundle，最低部署 15.0。MediaBenchmark 同样包含 113,633,363 字节素材，最低部署 15.0；三个实际配置包检查通过。 |
| 人工视觉 | 已检查两张深色截图（媒体堆叠返回、视频预览），未见该画面的遮挡／裁剪问题；完整外观与辅助功能矩阵未执行。 |
| 真机及真实服务 | 未执行；模拟器及包测试不能替代。 |

MediaBenchmark 构建日志为 `/tmp/AzureFish-fix-media-benchmark.log`；三个实际包检查为 `/tmp/AzureFish-fix-package-inspection.json`。

Release 构建日志为 `/tmp/AzureFish-fix-release.log`；UI 最终辅助方法构建日志为 `/tmp/AzureFish-fix-ui-build-2.log`。

UI 日志为 `/tmp/AzureFish-fix-ui.log` 与 `/tmp/AzureFish-fix-ui-rtl.log`、`/tmp/AzureFish-fix-ui-rtl-final.log`、`/tmp/AzureFish-fix-ui-ipad-recheck.log`，结果包保存对应截图；导出目录 `/tmp/AzureFish-fix-ui-attachments`。

应用最终编译日志为 `/tmp/AzureFish-fix-build-final-4.log`；组件全量尝试与受阻采样为 `/tmp/AzureFish-fix-unit-final-2.log`、`/tmp/AzureFish-fix-unit-hang.sample`，可运行部分为 `/tmp/AzureFish-fix-unit-unblocked.log`，独立复核为 `/tmp/AzureFish-fix-animation-recheck.log`、`/tmp/AzureFish-fix-services-recheck.log`。

包测试原始日志位于本机 `/tmp/AzureFish-fix-chat-final-3.log`、`/tmp/AzureFish-fix-storage-final.log`、`/tmp/AzureFish-fix-network-native.log`、`/tmp/AzureFish-fix-api.log`、`/tmp/AzureFish-fix-server-6.log`。这些路径是本次临时证据，不属于仓库长期交付物。

## 固定负载与复现

- ChatTimelineAndImportsTests：350 条时间线，200 条查询上限，加入第 351 条、撤回、隐藏与搜索上下文；已有 SQLCipher 基线升级、导入失败、共享引用与启动恢复。
- ChatLifecycleTests：可控迟到回包、停止排空、新同步状态；两个窗口共享 16 KiB 资源，独立取消、完整缓存复用与最后调用方取消后的重试。记录传输次数及字节。
- IMUnreadProjectionTests：与实际历史扫描计数对照，覆盖发送、本人消息、系统消息、撤回、阅读、移除、重入、解散和缺失投影回填；原服务端事务与密文测试同时回归。
- IMLiveCoordinatorTests：两个同账号 WebSocket、共享补偿批次、资料提示、失效会话与连接回收。
- IMReadPerformanceTests：固定 351 条消息（350 条用户消息加 1 条系统消息）、2 个成员、20 次读取，与本次修复前算法对照。查询计数由 Fluent QueryHistory 实测，仅输出次数、耗时和进程峰值，不记录正文或凭据。

```sh
python3 -m unittest discover -s Scripts/tests -v
python3 Scripts/sync-server-protocol.py --server AzureFishServer --check
swift test --package-path SharePackage/AzureFishChat -j 4
swift test --package-path SharePackage/AzureFishStorage -j 4
swift test --package-path SharePackage/AzureFishNetwork -j 4
swift test --package-path SharePackage/AzureFishAPI -j 4
AZUREFISH_RUN_READ_BENCHMARK=1 AZUREFISH_RUN_CLIENT_REALTIME=1 swift test --package-path AzureFishServer -j 4
```

本机配置包复现（Intel 主机；Apple Silicon 不使用 `ARCHS=x86_64`）。单元／组件运行需要能访问 Keychain 的签名模拟器包，未签名构建仅作为编译证据；本次使用临时签名。切换 scheme 前先完成对应运行，避免共享 DerivedData 中的测试插件被后续构建调整。

```sh
xcodebuild -workspace AzureFish.xcworkspace -scheme AzureFish -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/AzureFish-Fix-DD -onlyUsePackageVersionsFromResolvedFile -jobs 4 ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing
xcodebuild -workspace AzureFish.xcworkspace -scheme ChatRegression -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/AzureFish-Fix-DD -onlyUsePackageVersionsFromResolvedFile -jobs 4 ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing
xcodebuild -workspace AzureFish.xcworkspace -scheme AzureFish -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/AzureFish-Fix-DD -onlyUsePackageVersionsFromResolvedFile -jobs 4 ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
xcodebuild -workspace AzureFish.xcworkspace -scheme MediaBenchmark -configuration MediaBenchmark -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/AzureFish-Fix-DD -onlyUsePackageVersionsFromResolvedFile -jobs 4 ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build-for-testing
```

本机独立进程固定负载结果（单次样本，351 条、2 个成员、20 次读取）：

| 算法 | 数据库查询 | 20 次读取耗时 | 测试进程峰值内存 |
| --- | ---: | ---: | ---: |
| 修复前扫描 | 80 | 1.651 秒 | 44.8 MiB |
| 未读投影 | 40 | 0.051 秒 | 42.2 MiB |

峰值来自 Darwin `getrusage`，包含测试进程及初始化；并非 iOS 真机物理内存，也不是业务库单独的内存占用。固定样本不能外推所有部署的尾延迟。原始日志为 `/tmp/AzureFish-fix-read-baseline.log` 和 `/tmp/AzureFish-fix-read-projected.log`。两个窗口同时请求同一 16 KiB 资源时，测试确认底层仅下载一次；取消其中一个调用方后另一方仍完成，随后缓存命中不新增下载。媒体组件测试另外核对列表只请求 thumbnail，用户打开后才请求 original。

```sh
AZUREFISH_RUN_READ_BENCHMARK=1 AZUREFISH_READ_BENCHMARK_MODE=baseline swift test --package-path AzureFishServer -j 4 --filter IMReadPerformanceTests
AZUREFISH_RUN_READ_BENCHMARK=1 AZUREFISH_READ_BENCHMARK_MODE=projected swift test --package-path AzureFishServer -j 4 --filter IMReadPerformanceTests
```

客户端独立实时联调前先编译 AzureFishAPI 测试；随机回环端口和临时数据库仅使用虚构数据。真机媒体 A/B 沿用[固定素材与指标流程](../../Scripts/media-benchmark/README.md)，没有真机证据不改变并发参数。

## 尚未完成的验收

iOS 15～25、iOS 27.1 Duo、真机、真实服务 HTTPS、真实账号、Apple 登录及完整四语言／主题／辅助功能人工矩阵未执行；本机模拟器结果不证明这些路径。峰值物理内存与真实滚动卡顿采用既有真机 A/B 流程，当前不以桌面包测试估计或选择并发参数。
