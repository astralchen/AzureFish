# 本次运行截图

所有图片均来自 2026-09-27 的 iOS 26.5 模拟器运行；不是 Figma 或生成效果图。

- `live-light.png`、`live-dark-rtl.png`：真实会话工厂及 LiveChatSession 的虚构离线账号组件运行图；真实导航、富文本气泡、回执、原输入栏。截图由实际 UIWindow 绘制，不能当作真实 HTTP 界面联调。
- `ipad-live-light.png`、`ipad-live-dark-rtl.png`：同一真实适配组件在 iPad Pro 11 英寸模拟器的运行图。深色导航和玻璃对比度仍待实际屏幕复核，未计为人工视觉通过。
- `history-audio-anchor.png`：转写更新后保留阅读锚点的真实列表，严格位移断言通过。
- `demo-mixed-draft-restored.png`：原版演示 UI 的照片／GIF／Live Photo／视频草稿重启恢复。
- `demo-media-preview.png`：上述草稿的原版系统交互预览。
- `demo-mixed-sent.png`：发送后再次启动，草稿保持清空；演示消息本身不持久化。
- `demo-initial-history.png`：原版确定性历史首帧到底部并保持稳定。
- `demo-keyboard-photo-handoff.png`：键盘切换到原版照片面板后，输入栏保持原来的 539 pt 底边；此图记录交接几何，照片内容尚在系统加载中。

真实会话截图与原版演示截图分别标识，不能把演示导航或模拟业务作为真实会话证据。完整通过、失败和未执行项目见[接入记录](../../original-ui-restoration.md)。
