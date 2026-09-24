# 登录与个人中心开发文档

> **状态：设计阶段，尚未接入应用。** 更新日期：2026-09-24。本目录仅交付 Markdown，没有修改 App 路由、网络层、SwiftProtobuf 依赖或 UI。

AzureFish 是 iOS 客户端；相邻的 AzureFishServer 是独立 Swift 服务端。登录和用户模块首期共用一个服务端进程，后续 IM 复用身份和会话。客户端数据库与服务端数据库各有职责，不共享文件。

## 阅读入口

| 文档 | 内容 |
| --- | --- |
| [客户端接入](client-integration.md) | URLSession、Protobuf、Keychain、认证状态机、账号切换与生成产物同步 |
| [苹果风格 UI／UX](ui-ux.md) | 登录、注册、资料、账号安全、错误、无障碍和系统兼容 |
| [数据安全](../Security/README.md) | HTTPS、SQLCipher、媒体加密、Keychain 与数据恢复 |
| [多设备规范](../Design/README.md) | iPhone、iPad、iOS 27.1 Duo 的布局与状态连续性 |
| [四语言规范](../Internationalization/README.md) | 简中、繁中、英文、阿拉伯语、跟随系统与 RTL |
| [客户端验收](validation.md) | 单元、组件、模拟器、真机与真实 Apple 的分别验证 |
| [服务端总入口](../../../AzureFishServer/README.md) | 独立服务工程的架构、开发顺序和初学者教程 |
| [网络协议字典](../../../AzureFishServer/Documentation/protobuf-contract.md) | 唯一接口消息与字段编号来源 |
| [现有本地数据库设计](../Database/README.md) | 每账号数据隔离、媒体所有权、后续 IM 本地存储 |

跨工程相对链接要求按相邻目录摆放，便于本机阅读；未来编译不依赖相邻工程存在。客户端不另写一份 .proto，服务器协议为唯一权威来源。

## 既定范围

- 账号密码和 Apple 登录，可显式绑定同一用户；不按邮箱自动合并。
- 昵称、头像、简介、登录方式、设置／修改密码、退出和删除账号。
- iOS 15+，UIKit＋QuickLayoutKit＋同文件 #Preview，苹果系统风格；简体中文、繁体中文、英文、阿拉伯语。
- Mac 本地服务先用虚构数据连模拟器；真实账号及 Apple 使用 HTTPS，真机采用局域网 HTTPS；不关闭证书校验。
- 登录后现有聊天仍为本地演示，未接入真实好友、会话或消息服务。

## 与当前代码的关系

现有 [SceneDelegate](../../AzureFish/SceneDelegate.swift) 正常启动直接进入 iOS 26+ ChatViewController 或旧系统 LegacyChatViewController；后续才引入认证协调器和个人中心。保留现有 Debug 回归入口，不把登录页强行插入无关聊天测试。

后续先完成加密依赖与密钥可行性，再实现服务端账号／用户及四语言自适应认证 UI，随后多设备联调和独立 IM。

本轮没有创建 Swift／.proto／SQL／Package.swift、安装依赖或运行服务。后续代码阶段按服务底座 → 密码和用户 → Apple → iOS 接入 → IM 的顺序执行；详见服务端文档。
