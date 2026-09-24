# 2026-09-24 动画断言与诊断日志修复同步

先在 QuickLayoutKit 源工程修复和验证，再同步到 AzureFish。来源为 `54d74d9032e85f310f122493256f41bc04790a41` 上的本地未提交修改，本次未提交或推送 Git。

## 修改内容

- 新增 `ChatDiagnostics`。仅 Debug 构建的本次进程传入 `-chat-debug-logs true` 时开启；未传参数、缺少值、值为 false、大小写不匹配或重复参数均关闭。Release 始终关闭，不读取 UserDefaults。
- `[ChatScroll]` 使用 OSLog.Logger；关闭时在读取几何和构造字符串之前返回。样例历史与附件预览 fixture 的诊断也接入此开关。
- 修复 `composerDictationAndInterruptedHintShareContinuousGeometry` 和 `composerAudioPanelAnimatesWithoutRestartingForMeterUpdates` 的固定延时假设：提交渲染事务后观察真实呈现中间帧，按动画结束、提示隐藏和退出面板移除状态判断完成，最多等待 2 秒，超时仍失败。
- 保留几何连续性、淡入透明度、计量更新不重启动画和视图清理断言。未调整业务动画时长或视觉参数；本次修复的是测试采样与完成判断，前次偶发失败不能据此认定为已证实的业务动画缺陷。
- 同步 7 个文件，保留 AzureFish 的模块名、iOS 15 等待 API 适配以及现有工程配置。聊天模块现有 122 个 Swift 文件，逐一比对仅有日志 subsystem 的工程名差异。

## 验证结果

环境：Xcode 26.6（17F113），iPhone 17 Pro / iOS 26.5 模拟器。

| 项目 | 结果 |
| --- | --- |
| QuickLayoutKit Demo 构建 | 通过 |
| 源工程动画、日志开关、全屏布局回归 | 连续 3 轮通过，共 30 次测试执行；两项动画每轮均执行通过 |
| AzureFish 应用与测试构建 | 通过 |
| AzureFish 选定单元／组件回归 | 86 项通过，0 失败，包含前次失败的两项动画 |
| AzureFish 正常入口、输入发送 UI 回归 | 1 项通过 |
| 实际启动未传日志参数 | 采集到 0 条 ChatScroll |
| 实际启动传入 false | 采集到 0 条 ChatScroll |
| 实际启动传入 true | 采集到 10 条 ChatScroll |
| 部署目标与依赖检查 | 保持 iOS 15.0，框架仍为远程 Swift Package 引用 |
| 真机、旧系统完整 UI、Release 运行验证 | 未执行 |

验证后恢复默认无日志启动。上一次增量同步的首轮失败记录保留在 `sync-2026-09-24.md`，本记录为修复后的验证结果。

## 使用方式

Xcode → Product → Scheme → Edit Scheme → Run → Arguments → Arguments Passed On Launch，添加并勾选两行：

```text
-chat-debug-logs
true
```

## 证据

- 源工程构建：`/tmp/chat-animation-source-build-final.log`
- 源工程三轮回归：`/tmp/chat-animation-source-tests.log`、`/tmp/ChatAnimation-Source-Fix.xcresult`
- AzureFish 构建：`/tmp/azurefish-chat-diagnostics-build.log`
- AzureFish 回归：`/tmp/azurefish-chat-diagnostics-tests.log`、`/tmp/AzureFish-Chat-Diagnostics-Fix.xcresult`
- 日志采集汇总：同目录 `runtime-log-check-2026-09-24.json`
- 原文件备份和采集原文：`/tmp/chat-animation-diagnostics-sync/`
