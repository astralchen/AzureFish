# AzureFish 登录与个人中心 Figma 交接

> 2026-09-26：设计交付完成，客户端功能仍待接入。本轮仅制作 Figma 与本文档，没有修改 Swift、网络协议或数据库。

[打开 Figma Design 文件](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=29-1714) · 团队 **870498981's team** · 已选方向 **02：顶部品牌、大标题、底部操作**。

## 交付范围

工程内保存了 [本地设计归档](Archive/2026-09-26/README.md) 和离线浏览入口。归档包含 8 页总览、封面、28 张单页稿及设计数据；原生 `.fig` 与剩余单页高清稿因浏览器登录和 Figma 导出额度限制尚未取得，详情见归档说明。

- 8 个页面：导览与流程、基础样式、组件、认证、个人资料、账号安全、设置、适配与验收。
- 93 个页面／业务状态，712 个有效语言与主题实例；认证 184、个人资料 192、账号安全 288、设置 48。
- 简中、繁中、英文、阿拉伯语；浅色、深色及阿拉伯语 RTL。手动语言偏好只展示对应界面语言，手动浅色／深色只展示对应主题，不复制无效组合。用户昵称、简介、账号和图像不随界面语言翻译或镜像。
- 8 组本地组件集、47 个状态变体，另有品牌与 20 个 SF Symbols 图标组件；53 个变量、24 个文字样式。页面使用 Auto Layout、可编辑文字与组件实例。概念参考图仅保留在导览封面。
- 97 个预设演示场景、361 条有效目标连线（含封面入口），覆盖登录、注册、资料、头像、安全、删除和设置。13 个适配专项实例。

## 评审入口

| 入口 | 链接 |
| --- | --- |
| 欢迎 → 登录／注册 | [开始演示](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=24-2&starting-point-node-id=24%3A2) |
| 个人中心 → 编辑／设置 | [页面与连线](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=24-725) |
| Apple-only → 设置密码 | [页面与连线](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=25-1030) |
| 资料版本冲突与恢复 | [页面与连线](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=24-1157) |
| 删除账号 | [说明与确认](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=25-1757) |
| 阿拉伯语设置 | [RTL 场景](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=25-2211) |
| 开发与验收注释 | [适配与验收](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=38-2169) |

原型使用虚构数据及预设结果。它不执行真实输入验证、系统授权、上传、服务器操作或全局偏好同步。欢迎菜单选择可演示结果外观，跨流程仍使用预设场景；真实语言／外观连续性需要应用实现与测试。演示等待后的自动跳转不是服务器完成保证。

## 权威规则与实现边界

规则以 [服务端契约](../../AzureFishServer/Documentation/protobuf-contract.md)、[认证 UI／UX](../Authentication/ui-ux.md)、[多设备布局](README.md)、[国际化](../Internationalization/README.md) 和 [安全验收](../Security/validation.md) 为准。设计注释不建立第二套网络契约。

- 账号 trim 后小写，3～32 个 ASCII `[a-z0-9_]`。密码不 trim、不规范化，至少 12 个 Swift Character、至多 72 个 UTF-8 字节，禁止 NUL。昵称必填、不得全空白、最多 64 Character；简介最多 500，可清空。资料拒绝换行以外的控制字符。
- 头像独立确认提交，成功后立即生效；取消文字编辑不撤销头像。上传失败保留原头像与可重试预览；版本冲突保留草稿并重新读取最新版本，不静默覆盖。
- Apple 授权、相册、权限界面属于系统接管。绑定必须等待服务端结果；Apple-only 设置密码先完成最近身份确认。解绑必须已有密码，Apple 来源会话成功后需密码重新登录；密码来源会话刷新登录方式。
- 当前设备退出默认保留加密记录；离线只做本机退出并说明服务端状态待同步。全部设备退出、改密和删除等待真实结果；改密成功后全设备退出。HTTP 202 文案为“删除申请已受理”。无找回密码入口。
- Figma 导入官方 iOS 组件库时权限受限，采用本地可编辑组件补齐。实现仍应使用系统控件；Apple 按钮使用平台组件。CJK 的 Noto Sans SC／TC 是设计时字形替代，客户端继续使用原生系统字体。
- 15～25 非玻璃，26+ 系统 Liquid Glass 限导航和控件。Figma 模糊只表达意图。Duo 按现有文档描述窗口和局部遮挡，未编造设备尺寸或新增专用 API 保证。
- 当前客户端认证界面、Keychain 协调、主题偏好和繁中仍待接入；服务端 Apple、头像、改密、删除与真实 IM 仍未实现。既有历史验证不计入本次结果。

## 静态验收记录

| 项目 | 本次结果与范围 |
| --- | --- |
| 状态与语言结构 | 通过：93 个状态、712 个有效实例；133 组主要四语言文案无缺项。未执行母语专家审校 |
| 文字／控件结构 | 通过：712 个业务稿未发现可见文字宽于直接父容器，已命名 Action／Row 操作目标均 ≥44×44 pt；先前对返回／尾部操作的扫描也未发现小目标 |
| 组件与适配修正 | 已修正字段／按钮／标签栏自适应、320 pt 品牌排布、RTL 返回、文字高度和主题变量刷新 |
| 对比度 | 主操作 #0062CC 与白色文字计算比值 5.80:1；代表页面已人工查看。未声称所有颜色组合经过自动化 WCAG 验证 |
| 原型目标 | 通过：361 个链接目标存在且处于同一原型页；97 个演示场景；实际 ON_CLICK 来源未发现小于 44×44 pt 的区域。未执行浏览器逐路径点击验收 |
| 实际渲染审阅 | 已执行：欢迎／菜单、登录、阿拉伯语注册错误与资料编辑、长用户内容、Apple-only、安全确认、删除确认、基础样式、封面、320 pt、大字体和 iPad 等代表稿 |
| 应用编译／单元与组件测试 | 未执行：本轮没有应用代码变更 |
| 模拟器／真机／真实服务 | 未执行 |
| VoiceOver、键盘、首帧、多窗口连续性 | 已交付开发注释；运行验证未执行 |
| 仓库文档 | 通过：2 份文档的相对链接有效，`git diff --check` 无错误；新增交接文档另行检查尾随空白和围栏 |

专项稿包括 320 pt 欢迎／深色登录／RTL 错误，中文与阿拉伯语大字体，旧系统浅深色非玻璃，降低透明度、增强对比度，以及 iPad 窄窗口、宽屏认证、双列资料、双列敏感表单。1194×834 和 600×900 只是测试窗口，不是按设备名称分支的依据。长内容滚动容器保留纵向滚动。

Figma 验收页记录焦点与 VoiceOver 顺序、标签、密码可见性、键盘避让、返回焦点恢复、系统接管和状态保留要求。静态设计不能证明上述运行行为。

## 页面状态索引

每行可直接打开独立检查实例。详细入口、操作、取消和恢复在 Figma 的四组“流程索引”中。所有错误共用“保留输入和导航上下文，重新执行当前操作”的恢复原则，具体契约优先。

| 状态 | 页面 | 返回／取消 |
| --- | --- | --- |
| `welcome` | [欢迎来到 AzureFish](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=9-3) | 终态按主操作继续 |
| `login.empty` | [账号登录](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=9-213) | `welcome` |
| `login.filled` | [账号登录](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=13-708) | `welcome` |
| `login.focused` | [账号登录](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=13-946) | `welcome` |
| `login.error` | [账号登录](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=13-1184) | `welcome` |
| `login.loading` | [账号登录](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=13-1462) | `welcome` |
| `login.offline` | [账号登录](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=13-1700) | `welcome` |
| `login.timeout` | [账号登录](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=13-1978) | `welcome` |
| `login.passwordVisible` | [账号登录](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-1229) | `welcome` |
| `register.empty` | [注册账号](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-1479) | `welcome` |
| `register.mismatch` | [注册账号](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-1829) | `welcome` |
| `register.taken` | [注册账号](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-2147) | `welcome` |
| `register.loading` | [注册账号](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-2497) | `welcome` |
| `register.offline` | [注册账号](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-2847) | `welcome` |
| `apple.handoff` | [继续使用 Apple](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-3237) | `welcome` |
| `apple.cancelled` | [欢迎来到 AzureFish](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-3411) | 终态按主操作继续 |
| `apple.failed` | [欢迎来到 AzureFish](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-4135) | 终态按主操作继续 |
| `apple.conflict` | [欢迎来到 AzureFish](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-4385) | 终态按主操作继续 |
| `complete` | [完善个人资料](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-4635) | `welcome` |
| `complete.failed` | [完善个人资料](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-4905) | `welcome` |
| `complete.skipped` | [完善个人资料](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-5215) | `welcome` |
| `me` | [我](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=12-36) | 终态按主操作继续 |
| `me.long` | [我](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-5525) | 终态按主操作继续 |
| `me.incomplete` | [我](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-5915) | 终态按主操作继续 |
| `me.offline` | [我](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-6345) | 终态按主操作继续 |
| `me.loading` | [我](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-6775) | 终态按主操作继续 |
| `storage` | [本机资料暂不可用](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-7205) | `me` |
| `recovery` | [恢复说明](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-7379) | `storage` |
| `edit` | [编辑资料](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=12-498) | `me` |
| `edit.dirty` | [编辑资料](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-7537) | `edit.discard` |
| `edit.saving` | [编辑资料](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=15-7791) | `me` |
| `edit.error` | [编辑资料](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=16-1949) | `me` |
| `edit.conflict` | [编辑资料](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=16-2247) | `me` |
| `edit.saved` | [编辑资料](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=16-2557) | `me` |
| `edit.reloaded` | [资料已在其他设备更新](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=16-2855) | `edit` |
| `edit.discard` | [放弃修改](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=16-6603) | `edit.dirty` |
| `nickname` | [昵称](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=16-6745) | `edit` |
| `bio` | [简介](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=16-6903) | `edit` |
| `avatar` | [头像](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=16-7061) | `edit` |
| `avatar.preview` | [头像预览](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=16-7331) | `avatar` |
| `avatar.uploading` | [头像预览](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=16-7481) | `avatar` |
| `avatar.failed` | [头像预览](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=16-7671) | `avatar` |
| `avatar.format` | [头像预览](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=16-7861) | `avatar` |
| `avatar.permission` | [无法访问照片](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=16-8051) | `avatar` |
| `avatar.restore` | [恢复默认头像](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=16-8225) | `avatar` |
| `security.password` | [账号与安全](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-3) | `me` |
| `security.apple` | [账号与安全](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-357) | `me` |
| `security.both` | [账号与安全](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-699) | `me` |
| `methods.password` | [登录方式](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-1041) | `security.password` |
| `methods.apple` | [登录方式](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-1279) | `security.apple` |
| `methods.both` | [登录方式](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-1493) | `security.both` |
| `methods.binding` | [登录方式](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-1707) | `security.both` |
| `methods.revoked` | [登录方式](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-1921) | `security.both` |
| `methods.conflict` | [登录方式](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-9179) | `security.both` |
| `reauth.password` | [确认是你本人](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-9457) | `security.password` |
| `reauth.apple` | [确认是你本人](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-9671) | `security.apple` |
| `reauth.bind` | [确认是你本人](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-9813) | `security.password` |
| `reauth.delete` | [确认是你本人](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-10027) | `security.password` |
| `reauth.all` | [确认是你本人](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-10241) | `security.password` |
| `reauth.expired` | [确认是你本人](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-10455) | `security.password` |
| `setPassword` | [设置账号密码](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=17-10709) | `security.apple` |
| `changePassword` | [修改密码](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-2421) | `security.password` |
| `password.error` | [修改密码](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-2691) | `security.password` |
| `password.loading` | [修改密码](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-2929) | `security.password` |
| `password.changed` | [修改密码](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-3199) | 终态按主操作继续 |
| `password.set` | [设置账号密码](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-10403) | 终态按主操作继续 |
| `unbind` | [解除 Apple 关联](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-10593) | `methods.both` |
| `reauth.unbind` | [确认是你本人](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-10735) | `unbind` |
| `unbind.processing` | [解除 Apple 关联](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-10933) | `methods.both` |
| `logout` | [退出登录](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-11091) | `me` |
| `logout.offline` | [退出登录](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-11233) | `me.offline` |
| `logoutAll` | [退出全部设备](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-11375) | `security.password` |
| `logoutAll.confirm` | [退出全部设备](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-11533) | `security.password` |
| `logoutAll.error` | [退出全部设备](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-11675) | `security.password` |
| `delete` | [删除账号](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-11857) | `security.password` |
| `delete.confirm` | [确认删除账号？](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-12015) | `delete` |
| `delete.loading` | [删除账号](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=18-12157) | `security.password` |
| `delete.offline` | [删除账号](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=19-4021) | `security.password` |
| `delete.error` | [删除账号](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=19-4203) | `security.password` |
| `delete.accepted` | [删除申请已受理](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=19-4385) | 终态按主操作继续 |
| `session` | [登录已失效](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=19-4543) | 终态按主操作继续 |
| `settings` | [应用设置](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=19-11707) | `me` |
| `appearance.system` | [外观](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=19-11921) | `settings` |
| `appearance.light` | [外观](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=19-12199) | `settings` |
| `appearance.dark` | [外观](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=19-12339) | `settings` |
| `language.system` | [语言](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=19-12479) | `settings` |
| `language.zh-Hans` | [语言](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=19-12877) | `settings` |
| `language.zh-Hant` | [语言](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=19-12973) | `settings` |
| `language.en` | [语言](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=19-13069) | `settings` |
| `language.ar` | [语言](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=19-13165) | `settings` |
| `demo` | [本地演示](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=19-13281) | `me` |
| `welcome.appearance` | [外观](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=34-5225) | `welcome` |
| `welcome.language` | [语言](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=34-5689) | `welcome` |

## 后续实现验收

按 [认证验证矩阵](../Authentication/validation.md) 和 [安全与跨设备验收](../Security/validation.md) 执行真实验证。优先覆盖输入规则、最近确认过期、上传独立提交、冲突恢复、离线退出、删除受理，以及尺寸／主题／语言切换时不重复提交、不丢失焦点和输入。不能将本次 Figma 检查计为应用验证通过。
