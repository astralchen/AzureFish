# AzureFishStorage

Swift 6.3、iOS 15／macOS 12 的账号存储基础包。无 UIKit、网络契约或聊天模型依赖。SQLCipher GRDB 固定 revision 见 Package.swift。

`AccountDatabase` 由账号所有者创建，提供同步事务闭包和有序迁移。初始账本为 `account-storage-v1`，已有库先只读核对环境、账号和迁移前缀。旧开发库和未知版本报错，不自动擦除或替换密钥。`close()` 仅由最终所有者在全部业务停止后调用。

`EncryptedMediaStore` 保留既有分块 AES-GCM 文件格式与 AAD，资源描述使用基础值类型。明文只通过有期限租约提供，调用方及时 release；启动清理遗留租约。文件和密钥归同一环境／账号。

账号打开时为所有已安装业务注册 `registerResourceReferences`，查询必须使用传入 Database；删除时 `removeIfUnreferenced` 在数据库写入互斥区间内检查全部业务。文件删除失败由业务持久请求驱动重试，不删除仍被其他业务引用的文件。

测试：`swift test --package-path SharePackage/AzureFishStorage -j 4`。当前实现、表结构与验证边界见[数据库文档](../../Documentation/Database/README.md)。
