# 2026-09-27 应用设置 ListKit 优化

应用设置由分散的菜单按钮改为原生分组列表。首页分别展示外观与语言的保存偏好，点击进入独立选项页；选择立即生效，保持当前页面，使用系统返回按钮回到首页。

## 实施范围

- 三个页面各自持有直接滚动的 `UICollectionView` 与 `CollectionListAdapter`，没有外层 ScrollView 或 contentSize 高度拼接。
- 使用稳定 section／row ID、原生 `UICollectionViewListCell`、disclosure／checkmark accessory，以及 QuickLayoutKit 自适应组尾说明。
- 首页大标题、选项页紧凑标题；保留语言快捷菜单及正常业务路径上的标签栏。
- 分组宽度不超过 600 pt、水平边距至少 24 pt。窄屏及辅助功能字号下，首页当前值改为纵向排布，支持多行文本。
- 外观继续使用 `AppearancePreference.select`，在保存偏好变化后通知已加载页面；即使解析颜色相同，也刷新摘要与勾选。语言继续使用 `Localization.setLocale` 与现有场景协调机制。
- 勾选代表保存的偏好；跟随系统与手动选择严格区分。原偏好键、退出行为和服务器契约保持不变。

## 本次验收

| 检查 | 结果 | 本次范围 |
| --- | --- | --- |
| Debug 编译 | 通过 | Xcode 26.5，x86_64 模拟器，保留最低 iOS 15 部署目标 |
| 组件测试 | 通过 | 2 项；320／390／1024 pt 容器、最大 600 pt、边距至少 24 pt、行高至少 44 pt；大字体行高、组尾全文高度及两个已加载页面的外观摘要同步 |
| 偏好与持久化 UI | 通过 | 同一次运行切换浅色／深色／跟随系统，简中／繁中／英文／阿拉伯语／跟随系统；唯一选中状态、RTL→LTR、快捷菜单同步、返回摘要及重启恢复 |
| 正常页面入口 UI | 通过 | 使用原虚构账号进入“我 → 应用设置”；三个页面保持标签栏，选项页系统返回可用 |
| 大字体 UI | 通过 | 模拟器 `accessibility-medium`；首页摘要纵向布局，语言列表可点击，说明完整换行；结束后恢复原 `large` 字号 |
| 实际截图检查 | 通过 | 首页与选项页、深浅色、四语言和大字体；检查说明全文、箭头与值的间距、RTL 箭头和勾选位置 |
| 静态检查 | 通过 | `git diff --check`；记录内截图链接存在 |

复用唯一已启动的 iPhone 17 Pro／iOS 26.5 模拟器 `505FE0AF-BD0B-4257-A44A-A3BA1364CF5C` 与现有 DerivedData，关闭并行测试。不清空模拟器或账号数据；每次持久化用例只主动重启应用一次，其他启动用于切换测试入口。结束后恢复原偏好及字号，并打开正常本机虚构账号入口。

初轮自动化通过，但人工截图发现组尾说明被估算高度压成一行。修复为按给定宽度、不受估算高度限制进行垂直测量，并补充文字实际所需高度回归检查。修复后重新编译与运行，最终 2 项组件测试、3 项 UI 测试均通过。

最终证据：`/tmp/azurefish-settings-02.xcresult`、`/tmp/azurefish-settings-large-02.xcresult`。构建日志为 `/tmp/azurefish-settings-build.log`、`/tmp/azurefish-settings-rebuild.log`；最终运行日志为 `/tmp/azurefish-settings-retests.log`、`/tmp/azurefish-settings-large-retests.log`。这些临时结果由本机保留，以下 PNG 已归档进工程。

## 实际运行截图

- 正常入口：[首页](screens/settings-profile-overview.png)、[外观](screens/settings-profile-appearance.png)、[语言](screens/settings-profile-language.png)。
- 外观：[浅色首页](screens/settings-overview-light.png)、[深色首页](screens/settings-overview-dark.png)、[跟随系统勾选](screens/settings-appearance-system.png)。
- 语言：[简中](screens/settings-language-zh-Hans.png)、[繁中](screens/settings-language-zh-Hant.png)、[英文](screens/settings-language-en-US.png)、[阿拉伯语](screens/settings-language-ar.png)、[RTL 首页](screens/settings-overview-ar.png)、[恢复英文首页](screens/settings-overview-en.png)。
- 大字体：[首页](screens/settings-large-overview.png)、[语言选项](screens/settings-large-language.png)。

带 `profile` 的截图来自正常账号标签栏路径，其余来自只展示设置页的 Debug 入口。

## 验收边界

320／390／1024 pt 的组件布局检查不等于真实 iPad 窗口验收。旧系统、iPad、Duo、真机、多窗口实际运行、完整 VoiceOver 朗读与焦点操作、降低透明度及增强对比度尚未在本轮执行。设置模块不涉及真实服务授权；不将静态检查、预览或编译当作这些运行场景通过。
