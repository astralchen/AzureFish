# 登录与个人中心开发文档

> **状态：已实现客户端密码认证、资料与安装偏好，核心模拟器流程通过。** 更新日期：2026-09-26。仅限 Debug 模拟器和本机虚构账号服务，真实环境未开放。见 [实施与验收记录](client-implementation.md)。

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

现有 [SceneDelegate](../../AzureFish/SceneDelegate.swift) 正常启动经过 SessionCoordinator 恢复后进入欢迎页或“聊天／我”。聊天仍通过本地演示入口打开；显式 Debug 回归入口绕过认证，保留聊天测试。

已完成虚构账号范围内的加密依赖可行性与客户端接入；多设备完整验收、真实账号门槛和独立 IM 仍待完成。

独立 AzureFishServer 首期实现服务底座、注册、密码登录、刷新、当前会话退出和资料读写；仅限回环 HTTP＋虚构数据。服务端使用 Fluent SQLite 和字段加密，不代表客户端 SQLCipher 或真实账号安全门槛已经通过。权威字段编号见[服务端协议源](../../AzureFishServer/Protos/azurefish.proto)，运行与测试结果见[服务端验证记录](../../AzureFishServer/Documentation/validation.md)。

客户端通过三个独立本地 SPM 接入密码注册、登录、刷新、当前设备退出与资料读写。Apple、头像上传、密码设置／修改、退出全部设备和删除账号保留不可提交的说明入口，演示状态只在 Debug 目录中存在。真实 IM 尚未接入；实际验证范围见实施记录。
