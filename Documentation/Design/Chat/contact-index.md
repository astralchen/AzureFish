# 通讯录触摸索引

2026-09-29。通讯录沿用 ListKit 的 `.indexTitle(...)` 分组元数据，增加 `CollectionSectionIndexView`，通过 `CollectionListAdapter.sectionIndexView` 绑定。此前存在 UIKit 原生索引入口；本次增加的是明确托管的触摸区域、连续滑动定位及当前字母提示。

## 行为与接入

- 索引列出当前有联系人分组的标题，顺序与列表一致；点击或沿索引滑动定位对应分组，末组按列表实际滚动范围限制，不触发联系人导航。
- 滑动时在列表一侧显示当前字母提示，松手或取消后收起；采用系统语义颜色，无透明玻璃仿制。
- 搜索激活、搜索文字非空或没有联系人分组时隐藏索引；退出搜索后恢复，避免被键盘遮挡。新的朋友和黑名单不显示字母索引。
- QuickLayout 的 HStack 为索引保留 44 pt 宽度，避免覆盖联系人内容；RTL 使用语义尾侧。父 HStack 通过 `.safeAreaPadding(.horizontal)` 处理横向安全区域；索引只使用列表 `adjustedContentInset` 的 top／bottom 避开导航栏与底部栏，不再叠加 `safeAreaInsets`。ListKit 控件不依赖 QuickLayoutKit，宿主负责布局。
- 短窗口中稀疏绘制字母，避免重叠；触摸与辅助功能仍覆盖全部分组。
- VoiceOver 将索引呈现为可调整控件，逐项增减即可定位；辅助功能名称由 AzureFish 四语言 String Catalog 提供。
- ListKit 保留稳定行 identity 映射，在 snapshot 提交期间忽略索引定位。控件由页面持有、adapter 弱持有；原生索引与自定义索引不重复提供。

ListKit 远程 main 已确认包含 `7c453c49660574a0028bb78825af8b09cf459aa3`（`新增 Collection 分组触摸索引`）。AzureFish 已移除临时 `../ListKit` 本地 package 覆盖，恢复远程依赖，并在 `Package.resolved` 锁定该提交；无需同时检出 ListKit 仓库。其他远程依赖版本不变。

切换远程依赖后，已再次通过锁定版本解析及应用／测试目标 `build-for-testing` 编译，日志分别为 `/tmp/azurefish-listkit-remote-resolve.log` 和 `/tmp/azurefish-listkit-remote-build.log`。下表运行测试使用的是同一提交的本地源码；本次仅切换依赖来源，未重复执行运行测试。

## 本轮验证

| 项目 | 结果 |
| --- | --- |
| ListKit 索引组件测试 | 通过，5 项：几何命中／辅助功能调整、重排与重复标题映射／搜索隐藏／解除绑定、紧凑高度、可用视口 inset、弱引用释放 |
| 文案静态检查 | 通过，新增辅助功能文案覆盖简中、繁中、英文、阿拉伯语 |
| 应用及测试目标编译 | 通过，iOS 26.5 SDK／Intel 模拟器；最低目标 iOS 15 未提高 |
| AzureFish 通讯录单元／组件 | 通过，6 项；包括索引搜索显隐、320／768 pt 容器宽度、LTR／RTL，以及 844 × 390 pt 容器中非对称附加安全区域仅消费一次 |
| iPhone UI 回归 | 通过，2 项：81 位联系人 A～Z／# 点击与连续滑动定位、搜索隐藏与恢复；四语言请求与搜索流程，并断言索引可命中及语义尾侧位置 |
| 截图视觉检查 | 通过，检查首页、末组、搜索退出恢复及四语言索引；繁中和阿拉伯语使用深色与辅助功能大字体 |
| iPad 实机／模拟器、iOS 15～25、iOS 27.1 Duo、真机、真实服务 | 未执行；768 pt 组件布局不能替代 iPad 页面交互验收 |
| VoiceOver 朗读、降低透明度、增强对比度人工验收 | 未执行；组件调用断言不代替人工辅助功能验证 |

历史截图与历史通过结果不作为本次证据。

本轮运行设备为 iPhone 17 Pro／iOS 26.5 模拟器。应用测试结果位于 `/tmp/AzureFish-Keyboard-DD/Logs/Test/Test-AzureFish-2026.09.29_16-19-12-+0800.xcresult`，日志为 `/tmp/azurefish-index-safearea.log`；ListKit 测试日志为 `/tmp/listkit-index-viewport.log`。临时目录中的运行产物不随仓库保存。

本轮原始截图已归档，来源映射见 [manifest.json](Validation/contact-index-2026-09-29/manifest.json)：

- [完整索引首页](Validation/contact-index-2026-09-29/通讯录-字母索引首页.png)、[末组定位](Validation/contact-index-2026-09-29/通讯录-字母索引末组.png)、[退出搜索后恢复](Validation/contact-index-2026-09-29/通讯录-字母索引恢复.png)。
- [简体中文](Validation/contact-index-2026-09-29/通讯录-zh-Hans.png)、[繁体中文／深色大字体](Validation/contact-index-2026-09-29/通讯录-zh-Hant.png)、[英文](Validation/contact-index-2026-09-29/通讯录-en.png)、[阿拉伯语／RTL／深色大字体](Validation/contact-index-2026-09-29/通讯录-ar.png)。
