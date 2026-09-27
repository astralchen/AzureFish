# 2026-09-27 账号与安全 ListKit 优化

账号与安全改为与应用设置一致的原生分组列表，包含登录方式、安全操作和独立删除分组。密码状态只读；四个未开放功能显示明确状态，点击弹出对应名称与说明，仅允许关闭，不发出服务器操作。

## 实施

- `AccountSecurityViewController` 独立托管 `UICollectionView` 与 `CollectionListAdapter`，QuickLayoutKit 处理页面安全区域，无外层 ScrollView 或 contentSize 高度拼接。
- 稳定 section／row ID，原生列表 Cell、分组标题；复用可测量全文高度的组尾视图。无跳转箭头，删除标题使用系统红色。
- 最大内容宽度 600 pt、水平边距至少 24 pt、行高至少 44 pt；窄屏及辅助功能大字体使用纵向标题／状态。保留系统返回、大标题、语言菜单和正常路径标签栏。
- 新增文案提供简中、繁中、英文、阿拉伯语；沿用现有本地化与主题机制，不增加偏好键或账号数据字段。
- Debug `security.password` 接到真实列表。其余模拟状态不变；页面提供同文件默认、大字体与 RTL 预览。

## 验收

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| Debug 编译 | 通过 | Xcode 26.5，x86_64 模拟器，保持最低 iOS 15 部署目标 |
| 组件专项 | 通过 | 1 项；三组与 5 行结构、只读选择及无障碍语义、无跳转箭头、320／390／1024 pt 容器、600 pt 上限、24 pt 边距、44 pt 行高、组尾全文和大字体行高 |
| 正常入口 UI | 通过 | 原虚构账号进入安全页，四个入口逐一检查功能标题、单个关闭按钮、关闭后仍在页面且保留标签栏；密码状态点击无动作 |
| 四语言与主题 UI | 通过 | 同一次运行切换简中、繁中、英文、阿拉伯语并恢复 LTR；浅色、深色、跟随系统；系统返回和偏好恢复 |
| 大字体 UI | 通过 | 使用 `accessibility-medium`，检查说明换行、删除行完整滚入视野及关闭弹窗后保持可点击 |
| 人工视觉 | 通过 | 普通字号四语言、深浅色、删除说明和大字体；检查无重叠或截断及 RTL→LTR 的原生分隔线 |
| 静态检查 | 通过 | 新增 5 条文案均具备四语言；`git diff --check` |

复用 iPhone 17 Pro／iOS 26.5 模拟器 `505FE0AF-BD0B-4257-A44A-A3BA1364CF5C` 及已有 DerivedData，关闭并行测试，不清空数据、不退出当前虚构账号。大字体测试结束后恢复原字号，主题与语言测试恢复原偏好。

截图检查发现 native list 在方向切换后出现分隔线残留。最终处理为仅在方向变化时重新创建 compositional layout，并恢复原 contentOffset；CollectionView、稳定行 ID、导航和业务会话保持不变。最终截图确认 RTL 及返回英文都显示分隔线。大字体测试同时收紧为检查完整行进入可视范围，避免仅以部分可点击作为通过依据。

最终 1 项组件测试和 2 项 UI 测试通过。普通字号结果为 `/tmp/azurefish-security-04.xcresult`，大字体结果为 `/tmp/azurefish-security-large-04.xcresult`；运行日志为 `/tmp/azurefish-security-layout-tests.log`、`/tmp/azurefish-security-large-layout-tests.log`。构建日志为 `/tmp/azurefish-security-build.log` 和最终增量编译 `/tmp/azurefish-security-layout-build.log`。临时结果由本机保留，以下实际 PNG 已归档到工程。验收后确认模拟器字号恢复为原 `large`，主题及语言恢复原保存值。

## 运行截图

- [简中](screens/security-zh-Hans.png)、[繁中](screens/security-zh-Hant.png)、[英文](screens/security-en.png)、[阿拉伯语](screens/security-ar.png)、[恢复英文](screens/security-en-restored.png)。
- [浅色](screens/security-appearance-light.png)、[深色](screens/security-appearance-dark.png)、[跟随系统](screens/security-appearance-system.png)。
- [删除入口说明](screens/security-unavailable.png)。
- [大字体顶部](screens/security-large-top.png)、[大字体滚动后完整删除行](screens/security-large-bottom.png)。

普通字号截图来自正常账号与标签栏路径，大字体使用 `security.password` Debug 入口。

旧系统、iPad、Duo、真机及完整 VoiceOver 朗读／焦点操作未在本轮执行。容器尺寸组件测试不能替代对应设备运行验收；真实服务接口与真实账号验证不适用。
