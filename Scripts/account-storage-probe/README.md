# SQLCipher 可行性验证

隔离验证官方 `sqlcipher/GRDB.swift` 的固定 revision 与 SQLCipher 4.19.0。不链接进 AzureFish，不创建聊天业务数据库，不允许作为真实账号上线验收的替代。

```sh
swift test --package-path Scripts/account-storage-probe
```

用例覆盖随机测试密钥、schema migration、FTS5、加密备份、重开、无密钥／错误密钥拒绝，以及文件不包含明文 SQLite 头与虚构正文。错误密钥用例会产生 SQLCipher 的预期 HMAC 错误日志，最终以测试断言判断结果。

iOS 目标最低为 15。运行 iOS 测试时复用已启动的设备，并传入 `-parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`。本次编译与模拟器结果见 [实施验收记录](../../Documentation/Authentication/Implementation/2026-09-26.md)。
