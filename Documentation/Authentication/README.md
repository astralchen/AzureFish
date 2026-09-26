# 登录与个人中心开发文档

> **状态：客户端本地网络／账号 API 包已实现，认证尚未接入 App；服务端已实现首期密码账号接口。** 更新日期：2026-09-24。App 路由、Keychain、认证状态协调和 UI 仍待实施。

AzureFish 是 iOS 客户端；仓库根目录下的 `AzureFishServer/` 是独立 Swift 服务端。登录和用户模块首期共用一个服务端进程，后续 IM 复用身份和会话。客户端数据库与服务端数据库各有职责，不共享文件。

## 阅读入口

| 文档 | 内容 |
| --- | --- |
| [客户端接入](client-integration.md) | URLSession、Protobuf、Keychain、认证状态机、账号切换与生成产物同步 |
| [本地网络包](../Networking/README.md) | Swift 6.3 的 AzureFishProtocol／AzureFishNetwork／AzureFishAPI、测试及调用方式 |
| [苹果风格 UI／UX](ui-ux.md) | 登录、注册、资料、账号安全、错误、无障碍和系统兼容 |
| [数据安全](../Security/README.md) | HTTPS、SQLCipher、媒体加密、Keychain 与数据恢复 |
| [多设备规范](../Design/README.md) | iPhone、iPad、iOS 27.1 Duo 的布局与状态连续性 |
| [四语言规范](../Internationalization/README.md) | 简中、繁中、英文、阿拉伯语、跟随系统与 RTL |
| [客户端验收](validation.md) | 单元、组件、模拟器、真机与真实 Apple 的分别验证 |
| [服务端总入口](../../AzureFishServer/README.md) | 独立服务工程的架构、开发顺序和初学者教程 |
| [网络协议字典](../../AzureFishServer/Documentation/protobuf-contract.md) | 路由、消息语义与错误；字段编号以其引用的服务端 .proto 为准 |
| [现有本地数据库设计](../Database/README.md) | 每账号数据隔离、媒体所有权、后续 IM 本地存储 |

服务端位于本仓库的 `AzureFishServer/`，保持独立 Swift Package；客户端编译不依赖服务端目录。客户端同步带注释的 proto 副本供构建插件生成 Swift，服务器协议仍为唯一权威来源。

## 既定范围

- 账号密码和 Apple 登录，可显式绑定同一用户；不按邮箱自动合并。
- 昵称、头像、简介、登录方式、设置／修改密码、退出和删除账号。
- iOS 15+，UIKit＋QuickLayoutKit＋同文件 #Preview，苹果系统风格；简体中文、繁体中文、英文、阿拉伯语。
- Mac 本地服务先用虚构数据连模拟器；真实账号及 Apple 使用 HTTPS，真机采用局域网 HTTPS；不关闭证书校验。
- 登录后现有聊天仍为本地演示，未接入真实好友、会话或消息服务。

## 与当前代码的关系

现有 [SceneDelegate](../../AzureFish/SceneDelegate.swift) 正常启动直接进入 iOS 26+ ChatViewController 或旧系统 LegacyChatViewController；后续才引入认证协调器和个人中心。保留现有 Debug 回归入口，不把登录页强行插入无关聊天测试。

后续先完成加密依赖与密钥可行性，再实现服务端账号／用户及四语言自适应认证 UI，随后多设备联调和独立 IM。

独立 AzureFishServer 首期实现服务底座、注册、密码登录、刷新、当前会话退出和资料读写；仅限回环 HTTP＋虚构数据。服务端使用 Fluent SQLite 和字段加密，不代表客户端 SQLCipher 或真实账号安全门槛已经通过。权威字段编号见[服务端协议源](../../AzureFishServer/Protos/azurefish.proto)，运行与测试结果见[服务端验证记录](../../AzureFishServer/Documentation/validation.md)。

客户端已提供三个独立本地 SPM 和账号调用适配，已链接到 App target，账号流程与页面尚未接入。Apple、头像、密码设置／修改、退出全部设备、删除账号、客户端会话／UI 接入和 IM 仍待实施。后续依照既定顺序推进，在开放真实账号前完成安全文档中的验收门槛。
