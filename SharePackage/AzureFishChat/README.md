# AzureFishChat

账号范围内的聊天业务包。`ChatStore(database:)` 借用 AzureFishStorage 的账号数据库；关闭聊天实例不关闭共享库。App 的 AccountBusinessStorage 按环境和账号复用数据库及媒体，最终关闭由账号层负责。

Storage 目录包含按领域分离的 Record 与 Repository，所有关联读写通过调用者的同一事务。对外提供消息、草稿、展示、转写、检查点、私聊解析、联系人操作及上传批次接口，没有通用 meta 或泛型上传接口。StoredChatDraft 是不依赖 UIKit 的值快照，App 负责编辑器和资源描述转换。

消息正文按类型分表，子记录按 position 保存；媒体资产和物理资源可共享，摘要独立于历史。分页按页批量装配内容，不逐条发起关联查询。版本合并、稳定身份、取消和撤回终态由各业务规则维护。

测试：`swift test --package-path SharePackage/AzureFishChat -j 4`。结构、生命周期和本次验收见[数据库文档](../../Documentation/Database/README.md)。
