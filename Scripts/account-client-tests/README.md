# 客户端状态与存储测试

此包通过相对符号链接编译应用中的 `SessionCoordinator`、`CredentialStore`、`UserRepository` 和输入模型，避免维护第二份实现。

```sh
swift test --package-path Scripts/account-client-tests
```

仅补充主机验证，不加载 UIKit，也不代替系统 Keychain、iOS 文件保护和界面验收。模拟器测试使用 `AzureFishTests/Account` 与 `AzureFishUITests/Account`，结果见 [实施验收记录](../../Documentation/Authentication/Implementation/2026-09-26.md)。所有凭据样例均为虚构数据。
