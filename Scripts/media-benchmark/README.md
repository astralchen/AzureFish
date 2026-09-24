# 媒体并发 A/B 真机测试

测试构建使用 `MEDIA_BENCHMARK` 编译条件。普通构建不存在测试按钮或启动参数覆盖。
当前生产默认重处理并发是 2；系统 provider 导入最多 2 项，完整原图最多 1 项。

## 固定资源

`AzureFish/Resources/AttachmentPreviewResources.bundle/benchmark-manifest.json` 固定了 20 个有序项目及 SHA-256。
资源复用仓库真实 4032 × 3024 HEIC，并派生 JPEG、方向 6 JPEG、半透明 PNG 与 4032 × 1008 全景裁剪；
还有两张现有大尺寸 PNG。部分来源重复，但每次选择生成独立原件／缩略图 URL，避免共享解码缓存。
这些是固定格式负载，不代表 20 张独立拍摄照片的内容分布。
只有有意更换基准资源时才执行 `prepare-resources.swift`，重新生成并审核清单；A/B 测量之间不得运行。

## 构建与运行

使用现有签名配置对真机构建 MediaBenchmark scheme，Release `-O` 与 whole-module optimization 保持不变。
传入 `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) MEDIA_BENCHMARK DEBUG'`。
`DEBUG` 仅供已有 Demo 测试夹具编译；A/B 必须使用同一个已签名应用与测试运行器。
使用 `-onlyUsePackageVersionsFromResolvedFile` 固定依赖，不能在测量中构建其他版本。

1. `xcodebuild -workspace AzureFish.xcworkspace -scheme MediaBenchmark ... -configuration Release ... build-for-testing`（从仓库根目录执行）
2. `python3 Scripts/media-benchmark/configure-run.py <生成的.xctestrun> <输出.xctestrun> --pairs 20`
3. `xcodebuild test-without-building -xctestrun <输出> -destination 'platform=iOS,id=<UDID>' -parallel-testing-enabled NO -only-testing:AzureFishUITests/ChatMediaConcurrencyPerformanceTests -resultBundlePath <结果.xcresult>`

`--pairs 1` 仅做入口检查，不作为参数选择证据。每个测试先独立预热 A/B，然后记录 40 个样本，
按 AB、BA 交替配对；XCTest 自动丢弃的首个样本标记为 `sample: -1`。
冷态重新启动应用、创建新页面文件和图片缓存，不清除或声称清除系统文件缓存。
测试把亮度固定到 50%，设备维持同一有线供电条件；低电量或非正常温度时最多等待 300 秒。
每次启动前在测试运行器中等待相同的 10 秒冷却间隔，应用尚未启动且测量尚未开始；
可用 `--cooldown` 配置，但同一实验的 A/B 必须相同。该间隔不改变实际导入管线。
正式样本中出现内存警告、热状态变化、残留文件等会失败，不能选择性删除结果后继续声称 20 对有效样本。

## 指标

应用以实际状态回调记录 `firstReadyMs`、`allReadyMs`、原图真正设置到预览页的 `originals`。
XCTest 记录时钟、CPU、峰值物理内存、场景 signpost 和 XCTHitchMetric。
原图首次加载计时从打开请求开始，包含分类、排队、解码和设置；快速切页计时从最终目标选择开始。
精确导入计时从全部占位发布后开始，至最终就绪草稿发布结束。XCTest 时钟包含按钮操作和 AX 等待，
不用于评判 20 张纯导入速度。warm 场景在计时前完成导入；其他场景从计时后开始导入。

每个样本以 `MEDIA_AB_SAMPLE` JSON 输出到日志，并作为 JSON 附件保存。
`overlappingScrollSteps` 必须大于 0 才表明固定滚动脚本与导入有重叠。
不要把 CADisplayLink 间隔或缺失的 XCTHitchMetric 当作真实 Animation Hitches 指标。
若 XCTHitchMetric 无有效值，使用同设备 Animation Hitches 模板，对两组采用相同采集方式重测。

## 选择规则

20 对有效真机样本：B 的全部就绪中位数至少快 10%，至少 15 对更快；各场景峰值内存中位数增长不超过 20%；
原图 P90 增量不超过 max(50 ms, A × 10%)；卡顿时间比例增加不超过 max(1 ms/s, A × 10%)，
不能新增可归因于媒体处理的 >100 ms 界面停顿。全部满足保留 2；完整证据中任一门槛不满足采用 1。
真机或关键指标缺失，保留当前 2，不宣布赢家。本地 provider 结果不等同 iCloud 下载。

## 汇总与回归

使用 `xcrun xcresulttool get test-results metrics --path <结果包>` 导出 JSON，然后：

```sh
python3 Scripts/media-benchmark/summarize.py --log <测试日志> --metrics <指标.json> --hitches <已核对的卡顿.json> --output <汇总.json>
```

卡顿输入每行包含 `scenario`、`pair`、`limit`、`ratioMsPerSecond`、`newMediaStallOver100ms` 和指向原始 trace 的 `evidence`。
缺少配对或归因复核时，脚本返回 `incomplete_keep_2`；不能用空数组冒充零卡顿。

单元测试用 Demo scheme，UI 回归用 ChatRegression scheme。共享 DerivedData 时，后一个 scheme 的构建可能移除
前一个 scheme 的测试插件，因此应按“构建该 scheme → 运行其测试”的顺序执行，再切换 scheme。
`configure-run.py --limit 1/2` 同时传递期望值，`benchmarkLaunchConfigurationReachesPageLoader` 验证参数确实进入页面调度器。

## 日常使用的小样本对照

若目的是观察一次选择 20 张后的实际体验，可按用户选择运行少量配对，而非连续运行四场景 160 次正式样本：

```sh
python3 Scripts/media-benchmark/configure-run.py <原始.xctestrun> <日常对照.xctestrun> --pairs 3 --cooldown 10
xcodebuild test-without-building -xctestrun <日常对照.xctestrun> -destination 'platform=iOS,id=<UDID>' -parallel-testing-enabled NO -only-testing:AzureFishUITests/ChatMediaConcurrencyPerformanceTests/testColdImport -only-testing:AzureFishUITests/ChatMediaConcurrencyPerformanceTests/testPreviewDuringImport -resultBundlePath <日常对照.xcresult>
python3 Scripts/media-benchmark/summarize.py --log <日志> --metrics <指标.json> --pairs 3 --scene cold --scene preview --output <日常汇总.json>
```

此模式输出 `exploratory_keep_2`，提供中位数、P90 和原始样本，不声称完成原先 20 对的正式选值门槛。
每组只有 3 个样本时，最近秩 P90 就是该组最大值；它只描述本次样本，不估计所有用户的尾部延迟。
连续高频轮次的累积温升单独作为压力测试现象记录，不能直接判定日常单批导入失败。
