# 通讯录触摸索引

2026-09-29。通讯录沿用 ListKit 的 `.indexTitle(...)` 分组元数据，增加 `CollectionSectionIndexView`，通过 `CollectionListAdapter.sectionIndexView` 绑定。此前存在 UIKit 原生索引入口；本次增加的是明确托管的触摸区域、连续滑动定位及当前字母提示。

## 行为与接入

- 索引按 A–Z 列出当前有联系人的分组，中文显示名称使用系统普通话转写并去除声调，英文字母忽略大小写、重音及全半角；其他首字符归入末尾的 `#`。组内按同一拼音排序键排列，相同键以用户 ID 稳定排序。规则不随界面语言变化，备注仍优先于昵称；点击或沿索引滑动定位对应分组，末组按列表实际滚动范围限制，不触发联系人导航。
- 滑动时在列表一侧显示当前字母提示，松手或取消后收起；采用系统语义颜色，无透明玻璃仿制。
- 搜索激活、搜索文字非空或没有联系人分组时隐藏索引；退出搜索后恢复，避免被键盘遮挡。新的朋友和黑名单不显示字母索引。
- QuickLayout 的 ZStack 将 44 pt 索引覆盖在列表语义尾侧，列表、cell 背景和居中页脚保持完整容器宽度；行内容尾侧为索引额外预留 44 pt，居中页脚对称留白，搜索隐藏索引时恢复；分隔线尾侧 inset 固定为 0，延伸到 cell 边缘。父容器通过 `.safeAreaPadding(.horizontal)` 处理横向安全区域；索引只使用列表 `adjustedContentInset` 的 top／bottom 避开导航栏与底部栏，不再叠加 `safeAreaInsets`。ListKit 控件不依赖 QuickLayoutKit，宿主负责布局。
- 联系人行及“新的朋友”入口不显示跳转箭头；点击整行仍进入原有页面，头像和申请数量徽标保留。联系人头像放入固定 44 × 44 pt 的普通 accessory 容器，图片填满容器，隔离图片自身的对齐信息；容器与文字布局由 UIKit 管理。
- 短窗口中稀疏绘制字母，避免重叠；触摸与辅助功能仍覆盖全部分组。
- VoiceOver 将索引呈现为可调整控件，逐项增减即可定位；辅助功能名称由 AzureFish 四语言 String Catalog 提供。
- ListKit 保留稳定行 identity 映射，在 snapshot 提交期间忽略索引定位。控件由页面持有、adapter 弱持有；原生索引与自定义索引不重复提供。

ListKit 远程 main 已确认包含 `7c453c49660574a0028bb78825af8b09cf459aa3`（`新增 Collection 分组触摸索引`）。AzureFish 已移除临时 `../ListKit` 本地 package 覆盖，恢复远程依赖，并在 `Package.resolved` 锁定该提交；无需同时检出 ListKit 仓库。其他远程依赖版本不变。

切换远程依赖后，已再次通过锁定版本解析及应用／测试目标 `build-for-testing` 编译，日志分别为 `/tmp/azurefish-listkit-remote-resolve.log` 和 `/tmp/azurefish-listkit-remote-build.log`。下表运行测试使用的是同一提交的本地源码；本次仅切换依赖来源，未重复执行运行测试。

## 2026-09-29 联系人头像垂直居中修复

头像直接作为图片 accessory 时，实际显示中心偏离姓名／备注文字块。现在将头像放入固定 44 × 44 pt 的普通 UIView 容器，由系统对齐容器，图片使用 autoresizing 填满容器。该局部 UIKit 集成隔离了图片对齐信息，继续保留行高自适应、全宽选中背景、无箭头、分隔线贴边及拼音分组。

- 编译：通过。
- 单元／组件：`ChatContactsTests` 12 项通过。新增真实列表检查覆盖单行／双行文本、320／768 pt 容器、常规／AX5 字号、LTR／RTL、普通／选中状态、默认符号／照片切换，并等待后续布局周期验证位置保持；头像和文字块都与行中心对齐。
- 模拟器 UI：资料页点击回归 1 项通过；iPhone 17 Pro／iOS 26.5 深色截图视觉检查通过。[垂直居中截图](Validation/contact-width-pinyin-2026-09-29/contacts-vertically-centered.png)。
- 文档链接、Markdown 及 `git diff --check`：通过。
- 四语言 UI 全流程、iPad 实际页面、旧系统、真机、真实服务及辅助功能人工验收：此次未执行。

最终结果为 `/tmp/AzureFish-ContactAvatarContainer.xcresult`，日志为 `/tmp/azurefish-contact-avatar-container.log`（退出码 0）。此前仅修改头像坐标的尝试虽通过即时几何检查，但截图仍有偏移，已替换为容器方案；之前的截图不作为当前垂直对齐证据。测试坐标换算的尺寸比较采用 0.01 pt 容差，中心位置误差要求小于 1 pt。

## 2026-09-29 无箭头与分隔线贴边调整

按后续确认的样式，cell 保持整宽；移除联系人行和“新的朋友”入口的箭头，分隔线尾侧 inset 设为 0，延伸到行边缘。联系人行显式使用按钮无障碍语义，避免移除箭头后被 UIKit 识别为头像图片；UI 测试通过稳定标识定位整行。

- 编译、11 项 `ChatContactsTests`、1 项资料页点击 UI 回归：通过。组件测试同时检查整宽和按钮／非图片语义。
- iPhone 17 Pro／iOS 26.5 英文深色截图视觉检查：通过，确认无箭头、分隔线贴边；[最终截图](Validation/contact-width-pinyin-2026-09-29/contacts-no-arrows.png)。
- 文档链接及 `git diff --check`：通过。此次未重跑四语言 UI 全流程、其他设备、旧系统或真机；前述历史截图仍包含箭头，不作为最终样式依据。

最终结果为 `/tmp/AzureFish-Contacts-EdgeSeparators.xcresult`，日志为 `/tmp/azurefish-contacts-edge-separators.log`（退出码 0）。早期两次资料页 UI 测试因联系人行被识别为 Image 而失败，已通过显式按钮语义和按稳定标识定位修复，并完成上述复跑。

## 2026-09-29 cell 宽度与拼音修复验证

原 HStack 将整个列表压缩 44 pt，导致 cell 选中背景偏窄、页脚中心偏移；现改为整宽列表与尾侧索引叠放，内容和分隔线避让索引。中文分组从仅中文界面转写改为四种界面语言统一按拼音归入 A–Z，其他首字符归入 `#`。

| 项目 | 本次结果 |
| --- | --- |
| 文档链接、规则一致性、Markdown 与 `git diff --check` | 通过 |
| 应用及测试目标编译 | 通过，iOS 26.5 SDK，最低目标仍为 iOS 15 |
| 单元／组件测试 | 通过，`ChatContactsTests` 11 项；覆盖 320／402／768 pt 宽度、非对称安全区域、LTR／RTL、选中 cell 的整宽及内容避让、页脚居中、拼音分组与排序、繁体姓名、备注优先及 `#` 回退 |
| iPhone 模拟器 UI | 通过，2 项；四语言页面宽度及 `L` 拼音分组、搜索无结果、索引点击／拖动、搜索隐藏／恢复且宽度不变 |
| 截图视觉检查 | 通过，本次范围为英文常规字号、阿拉伯语 RTL／深色大字体的索引位置，以及完整 A–Z／# 恢复后的内容与分隔线避让 |
| iPad 页面交互、iOS 15～25、iOS 27.1 Duo、真机、真实服务 | 未执行；容器尺寸组件测试不能替代实际设备验证 |
| VoiceOver 朗读、降低透明度、增强对比度人工验收 | 未执行 |

最终运行设备为 iPhone 17 Pro／iOS 26.5，结果为 `/tmp/AzureFish-CellWidth-Pinyin-Final.xcresult`，日志为 `/tmp/azurefish-cell-width-final.log`（退出码 0）。截图来源见 [manifest.json](Validation/contact-width-pinyin-2026-09-29/manifest.json)：[英文拼音分组](Validation/contact-width-pinyin-2026-09-29/contacts-en.png)、[RTL 索引](Validation/contact-width-pinyin-2026-09-29/contacts-rtl.png)、[完整索引恢复](Validation/contact-width-pinyin-2026-09-29/index-restored.png)。

## 首次索引接入验证（宽度及拼音修复前）

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

以下结果及截图记录首次索引接入，不作为后续宽度及拼音修复的验证证据。

本轮运行设备为 iPhone 17 Pro／iOS 26.5 模拟器。应用测试结果位于 `/tmp/AzureFish-Keyboard-DD/Logs/Test/Test-AzureFish-2026.09.29_16-19-12-+0800.xcresult`，日志为 `/tmp/azurefish-index-safearea.log`；ListKit 测试日志为 `/tmp/listkit-index-viewport.log`。临时目录中的运行产物不随仓库保存。

本轮原始截图已归档，来源映射见 [manifest.json](Validation/contact-index-2026-09-29/manifest.json)：

- [完整索引首页](Validation/contact-index-2026-09-29/通讯录-字母索引首页.png)、[末组定位](Validation/contact-index-2026-09-29/通讯录-字母索引末组.png)、[退出搜索后恢复](Validation/contact-index-2026-09-29/通讯录-字母索引恢复.png)。
- [简体中文](Validation/contact-index-2026-09-29/通讯录-zh-Hans.png)、[繁体中文／深色大字体](Validation/contact-index-2026-09-29/通讯录-zh-Hant.png)、[英文](Validation/contact-index-2026-09-29/通讯录-en.png)、[阿拉伯语／RTL／深色大字体](Validation/contact-index-2026-09-29/通讯录-ar.png)。
