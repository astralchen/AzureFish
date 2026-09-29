# 通讯录缓存验证记录

日期：2026-09-29。实现约定见[通讯录本地优先缓存](../../contact-cache.md)。本轮使用隔离虚构账号、可控网络响应和 Debug UI 样例，未连接生产服务。

## 自动化范围

- `AzureFishChat`：31 个 Swift Testing 测试通过；真实服务联调测试 1 个按默认条件跳过。新增本地快照与检查点一致读取、空快照、分页中断重开和旧快照不恢复旧关系／资料的验证。
- 应用组件：34 个 Swift Testing 测试通过（8 个测试组，多轮去重计数；最终通讯录专项 9 项通过）。覆盖头像共享任务、磁盘命中、内存警告／预算淘汰、旧资源保留、账号／环境作用域、缺失／错误密钥及篡改拒绝；覆盖网络阻塞时本地发布、联系人查询去重、乱序资料和备注更新、默认头像、账号注销标记、旧头像晚到、退出失效、列表视图复用、搜索保留、会话成员离线打开已有资料及键盘避让。
- 编译：Xcode iOS 26.5 Simulator SDK，应用最低部署版本 iOS 15，Debug 应用和测试目标编译通过。未把编译结果视为旧系统运行验证。
- 模拟器 UI：iOS 26.5 的 iPhone 17 Pro 共 4 项、iPad Pro 11-inch (M5) 共 5 项通过（多轮去重）。覆盖四语言申请与搜索、深浅色、AX5、RTL、资料头像、联系人／备注／黑名单导航及字母索引；iPad 另覆盖横竖屏切换后继续编辑备注。iPhone 上的 iPad 专用旋转用例按条件跳过，不计入通过数。
- 文档与资源检查：8 份变更 Markdown 的本地链接无断链，新增状态文案四语言完整，`git diff --check` 通过。

## 命令与原始结果

聊天包运行 `swift test --package-path SharePackage/AzureFishChat`。应用运行 `xcodebuild -workspace AzureFish.xcworkspace -scheme AzureFish -destination 'platform=iOS Simulator,id=<设备 UUID>' -derivedDataPath /tmp/AzureFish-Keyboard-DD CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO test`，使用 `-only-testing` 限定上述组件和 `ChatContactsUITests`。

本机原始日志以 `/tmp/azurefish-contacts-cache-` 开头；结果包如下。临时路径不是仓库可长期下载的附件，仓库保留结论与选定截图。

| 结果包 | 本轮结果 |
| --- | --- |
| `/tmp/AzureFish-ContactCache-iPhone-Final2.xcresult` | 32 个组件测试及四语言、资料头像、索引 UI 通过 |
| `/tmp/AzureFish-ContactCache-iPad-Final.xcresult` | 33 个组件测试通过；4 项 UI 通过，索引旧断言失败 |
| `/tmp/AzureFish-ContactCache-iPad-Final2.xcresult` | 四语言 UI 通过；索引旧断言及新增键盘测试宿主初始化失败 |
| `/tmp/AzureFish-ContactCache-iPad-Final3.xcresult` | 索引 UI 通过；新增键盘测试宿主坐标断言失败，已改为场景窗口并在最终 iPhone 复测通过 |
| `/tmp/AzureFish-ContactCache-iPhone-Final3.xcresult` | 最终通讯录组件 9 项、四语言／索引 UI 2 项全部通过，命令退出 0 |

## 发现及修复

- 初轮新测试遗漏 iOS 15 API 可用性限制，以及测试假资料缺少合法字段，已修正测试并重新运行。键盘测试另外修正了视图未加载及未绑定 `UIWindowScene` 的宿主问题，使用真实场景窗口计算坐标。
- 申请行默认头像未填满预留方形区域：补充 QuickLayout `resizable()`，新增 44 × 44 pt 尺寸断言，已通过。
- 初轮繁体中文大字体搜索未获得输入焦点：搜索展开时跳过列表阅读锚点恢复，iPhone 四语言复测已通过。
- 搜索／首次加载状态曾沿用聊天文案，已增加独立四语言联系人状态文案；无有效 UUID 的虚构样例也统一显示默认头像。
- iPad 与 iPhone 并发启动时，iPad 测试宿主加载 Accessibility 超时，没有执行 UI 用例；改为串行复测，不将超时计为通过。
- iPad 首轮串行 UI 有 4 项通过、索引断言 1 项失败。录屏与复测确认原生内联按钮会同时清空文字并结束搜索；旧测试把 iPhone 的“清空后仍激活”当作跨平台保证。测试现在分别验证激活时隐藏、结束后恢复，并确认键盘关闭，专项已通过。运行时的搜索状态同时考虑呈现、实际焦点和 `UISearchController.isActive`。
- 大字体无结果提示受键盘遮挡：列表仅为完整停靠键盘增加 inset，浮动键盘不扩展成整页留白；新增提示区域及键盘关闭后的边距恢复断言。

## 验证边界

模拟器 UI 样例验证布局、导航、搜索和输入连续性；网络阻塞、乱序响应、加密与生命周期由组件／存储测试验证，不能据 UI 样例宣称真实服务端到端联调完成。磁盘保留规则由跨实例恢复及内存淘汰后的密文断言验证，没有等待长期自然时间。

iOS 15～25、iOS 27.1 Duo、真机、VoiceOver、降低透明度、增强对比度人工验收未执行；没有生产账号验收结果。

## 截图检查

以下为本轮 XCTest 原始截图，未合成或替换内容。已检查默认头像尺寸及 RTL 排列。AX5 的长申请行高于单屏，需滚动继续阅读；不把首屏截图当作所有可访问性条件的验收。iPad 竖屏截图中系统顶部 Tab 与备注编辑标题接近／重叠，是本轮记录的既有导航布局限制；输入状态验证通过不代表整个导航外观人工验收通过。

- [iPhone 繁中／深色／AX5 申请](iphone-requests-zh-Hant-dark-AX5.png)
- [iPhone 阿拉伯语／RTL／深色／AX5 申请](iphone-requests-ar-dark-AX5.png)
- [iPhone 深色资料页头像](iphone-profile-dark.png)
- [iPhone 英文浅色通讯录与离线提示](iphone-contacts-en-light.png)
- [iPhone 繁中／深色／AX5 搜索提示避让键盘](iphone-search-zh-Hant-dark-AX5.png)
- [iPad 横屏保留备注输入](ipad-remark-landscape.png)
- [iPad 恢复竖屏后继续输入](ipad-remark-portrait.png)
- [iPad 繁中／深色／AX5 搜索提示避让键盘](ipad-search-zh-Hant-dark-AX5.png)
- [iPad 结束搜索后恢复索引](ipad-index-restored.png)
