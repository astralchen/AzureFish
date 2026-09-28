# 列表数量徽标尺寸与居中修复

2026-09-27。针对通讯录“新的朋友”右侧红色数量被压成细条的问题。

## 原因与修复

共享列表把 `UILabel` 手动设置为 22 pt 高，并为文字预留左右内边距，但 `UICellAccessory.CustomViewConfiguration` 默认会重新计算视图尺寸。模拟器回归复现：`1` 的实际尺寸约为 6×14.33 pt；11 pt 圆角进一步裁切了数字和背景。

自定义 accessory 现在显式使用 `maintainsFixedSize: true` 和 `reservedLayoutWidth: .actual`。系统继续管理 trailing 位置与 disclosure indicator，保留已计算的圆形／胶囊尺寸：单个数字至少 22×22 pt，多位数按文字宽度加 12 pt。红色背景、白色数字、`99+`、零值隐藏规则不变。通讯录与聊天列表共用修复，Tab 徽标仍由系统绘制。

这是工程对既有设计尺寸的修复，没有改动导航、通讯录空状态或 Figma 设计。

## 垂直居中补充

尺寸修复后，直接作为 accessory 的 `UILabel` 仍使红色背景偏离行中心。徽标改为独立的 `UnreadCountBadgeView`，由 QuickLayoutKit 将内部文字铺满容器；系统负责容器的 trailing 排列与垂直定位。保留上述固定尺寸配置，不叠加手工 y 偏移。

回归测试增加两个几何断言：徽标在 cell 坐标中的中心与行中心一致，文字在徽标坐标中的中心与容器一致，容许最多 0.5 pt 的像素取整误差。同文件提供单个数字和 `99+` 的预览。

## 验证

- 修复前：`ChatUnreadBadgeTests` 复现 36 个尺寸断言失败，覆盖三个数量、三种宽度及 LTR／RTL。
- 尺寸修复轮次：通过。iPhone 17 Pro／iOS 26.5 Simulator，徽标回归 1 项（18 组尺寸／方向组合），全屏列表回归 4 项，共 5 项测试通过。
- 居中修复轮次：通过。在同一模拟器重新编译并执行徽标回归 1 项，18 组组合的尺寸、行内垂直中心、文字中心及清零复用均通过。检查导出的实际列表截图，徽标与右侧箭头居中对齐。文档链接与 `git diff --check` 通过；真机和旧系统运行未执行。
- [真实列表组件截图](Validation/UnreadBadge/list-badges.png)：使用固定数量和虚构文案，不读取账号数据。
- 测试使用真实 `UICollectionViewListCell` 与 ListKit adapter，检查 1／12／99+、320／390／700 pt、LTR／RTL、文字内边距及数量清零后的复用。
- 尺寸修复轮次同时回归 `ChatListStateTests`；居中修复仅运行徽标专项。不连接或修改 8080 服务。

日志：`/tmp/azurefish-badge-before.log`、`/tmp/azurefish-badge-after.log`、`/tmp/azurefish-badge-centered.log`。
