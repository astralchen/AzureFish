# 2026-09-27 个人中心 ListKit 修正

针对个人中心箭头紧挨文字、菜单分散、空内容占据间距及退出入口层级不清的问题，将菜单改为 `CollectionListAdapter<String>` 管理的原生分组列表。

- `ProfileMenuView` 使用稳定 Row 身份与 `UICollectionViewListCell`，导航行采用系统 disclosure accessory；刷新和退出分组，退出使用语义红色。
- 列表按真实 Cell 自适应测量更新高度，由外层页面统一滚动；保留 regular＋内容宽度至少 840 pt 的双列条件。
- 简介及反馈为空时不参与布局；昵称和账号收紧间距。刷新请求处理中禁用重复触发。
- UI 测试将个人中心入口从 UIButton 定位更新为原生 Cell 定位，已有注册闭环用例同步更新定位方式。

## 本次验证

| 项目 | 结果 | 范围 |
| --- | --- | --- |
| Debug 模拟器编译 | 通过 | Xcode 26.5，x86_64，最低部署目标 iOS 15 |
| ListKit 专项 UI | 通过 | 同一 iPhone 17 Pro／iOS 26.5；3 个导航行可点击且高度至少 44 pt；LTR 箭头位于右侧行尾，RTL 位于左侧行尾 |
| 状态与导航 | 通过 | 现有虚构账号恢复，进入编辑后返回，简中→阿拉伯语→简中，取消退出仍在个人中心 |
| 人工截图检查 | 通过 | 简中分组、间距与箭头；阿拉伯语方向及混合账号文本可读性 |
| git diff --check | 通过 | 本次工作区检查 |
| 其他尺寸、系统、辅助功能与真实服务 | 未执行 | 不将本次单机专项复验解释为完整适配矩阵通过 |

使用唯一已启动模拟器 `505FE0AF-BD0B-4257-A44A-A3BA1364CF5C`，关闭并行测试和额外模拟器目的地；未清空数据或退出现有账号。

初次用例因仍按 UIButton 查询原生 Cell 失败；读取 UI 层级确认后更新定位，最终 `/tmp/azurefish-profile-list-02.xcresult` 中专项用例通过（1 项，0 失败）。构建日志为 `/tmp/azurefish-profile-list-build.log`、`/tmp/azurefish-profile-list-rebuild.log`，运行日志为 `/tmp/azurefish-profile-list-ui.log`。

[简中运行截图](screens/profile-listkit-zh-Hans.png) · [阿拉伯语运行截图](screens/profile-listkit-ar.png)
