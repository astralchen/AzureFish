# 会话排序改造验收

2026-09-28；仅使用随机密钥、临时账号库与虚构资料，未操作真实账号或已有服务数据。

## 本轮范围

- 草稿摘要优先、附件草稿、编辑恢复隐藏、重复保存保持隐藏、清空保留会话、发送原子清理。
- 置顶折叠、未读统计、搜索临时展开、本机同账号多窗口与重启持久化。
- 排序保持置顶分组、消息活动时间倒序、会话 ID 升序；草稿、资料和已读不增减活动时间。

## 验证结果

| 类别 | 结果 | 本轮证据 |
| --- | --- | --- |
| 应用与测试编译 | 通过 | iPhone 17 Pro／iOS 26.5，`/tmp/azurefish-list-alignment-build-2.log`；最终字体修正同时通过下述增量 test 构建 |
| 列表存储专项 | 通过 | 7 项；`/tmp/azurefish-list-alignment-package.log` |
| AzureFishChat 完整测试包 | 通过 | 28 项通过，1 项依赖独立服务的条件用例默认跳过；`/tmp/azurefish-list-alignment-package-full.log` |
| iPhone 组件 | 通过 | 列表 2 项、草稿 11 项；`/tmp/AzureFish-List-Alignment-iPhone.xcresult`。字体调整后列表 2 项再次通过 |
| iPhone UI | 通过 | 3 项：四语言行显示、折叠／搜索、滑动未读／隐藏／删除确认；`/tmp/AzureFish-List-Alignment-iPhone.xcresult` |
| iPad 组件与 UI | 通过 | 列表 2 项及四语言折叠／搜索 UI 1 项；`/tmp/AzureFish-List-Alignment-iPad.xcresult` |
| 最终动态字体复测 | 通过 | 两台设备分别运行四语言折叠／搜索；`/tmp/AzureFish-List-Alignment-Font-iPhone.xcresult`、`/tmp/AzureFish-List-Alignment-Font-iPad.xcresult` |
| 视觉检查 | 通过（本轮样例） | 核对简中浅色、繁中／阿拉伯语深色 AX5、英语搜索及 iPad 宽列表代表截图。文字、草稿标识、按钮和 RTL 无重叠；超大字号允许换行和列表滚动 |
| 静态检查 | 通过 | 6 条新增文案四语言齐全；文档链接、24 张 PNG 摘要、`git diff --check` |

截图检查发现并修正了折叠按钮的文字与箭头动态字体不一致：使用当前控制器 trait 的字体，同时重配字号变化。下列截图全部来自修复后的实际 UIKit 测试宿主，不使用预览替代运行；[manifest.json](manifest.json) 保存来源测试包、附件信息与 SHA-256。

## 最终运行截图

| 设备／语言 | 展开与草稿 | 折叠 | 搜索临时展开 |
| --- | --- | --- | --- |
| iPhone 简中 · 浅色 | [截图](iphone-expanded-zh-Hans.png) | [截图](iphone-folded-zh-Hans.png) | [截图](iphone-search-zh-Hans.png) |
| iPhone 繁中 · 深色／AX5 | [截图](iphone-expanded-zh-Hant.png) | [截图](iphone-folded-zh-Hant.png) | [截图](iphone-search-zh-Hant.png) |
| iPhone 英文 · 浅色 | [截图](iphone-expanded-en.png) | [截图](iphone-folded-en.png) | [截图](iphone-search-en.png) |
| iPhone 阿拉伯语 · 深色／AX5 | [截图](iphone-expanded-ar.png) | [截图](iphone-folded-ar.png) | [截图](iphone-search-ar.png) |
| iPad 简中 · 浅色 | [截图](ipad-expanded-zh-Hans.png) | [截图](ipad-folded-zh-Hans.png) | [截图](ipad-search-zh-Hans.png) |
| iPad 繁中 · 深色／AX5 | [截图](ipad-expanded-zh-Hant.png) | [截图](ipad-folded-zh-Hant.png) | [截图](ipad-search-zh-Hant.png) |
| iPad 英文 · 浅色 | [截图](ipad-expanded-en.png) | [截图](ipad-folded-en.png) | [截图](ipad-search-en.png) |
| iPad 阿拉伯语 · 深色／AX5 | [截图](ipad-expanded-ar.png) | [截图](ipad-folded-ar.png) | [截图](ipad-search-ar.png) |

## 环境边界

本机只有 iOS 26.5 Simulator。本轮为 iPhone／iPad 竖屏及其不同容器宽度；窗口拖动缩放和横竖屏切换未另行执行，不沿用此前通讯录旋转结果。iOS 15～25 非玻璃、iOS 27.1／Duo、真机及 VoiceOver／降低透明度／增强对比度人工验收未执行；预览不替代运行。未声称与当前微信未公开排序细节完全一致。
