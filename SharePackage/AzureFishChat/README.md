# AzureFishChat

账号范围内的聊天业务包。`ChatStore(database:)` 借用 AzureFishStorage 的账号数据库；关闭聊天实例不关闭共享库。App 的 AccountBusinessStorage 按环境和账号复用数据库及媒体，最终关闭由账号层负责。

Storage 目录包含按领域分离的 Record 与 Repository，所有关联读写通过调用者的同一事务。对外提供消息、草稿、展示、转写、检查点、私聊解析、联系人操作及上传批次接口，没有通用 meta 或泛型上传接口。StoredChatDraft 是不依赖 UIKit 的值快照，App 负责编辑器和资源描述转换。

消息正文按类型分表，子记录按 position 保存；媒体资产和物理资源可共享，摘要独立于历史。分页按页批量装配内容，不逐条发起关联查询。版本合并、稳定身份、取消和撤回终态由各业务规则维护。

测试：`swift test --package-path SharePackage/AzureFishChat -j 4`。结构、生命周期和本次验收见[数据库文档](../../Documentation/Database/README.md)。

2026-10-06：ChatTimelineWindow 保留最早已加载序号，每次查询最多 200 条，展示总量不再限于 200 条。ChatEngineUpdate 区分目录、会话、消息和传输范围；空范围只发布同步／连接状态。ChatDownloadCoordinator 按环境、账号及资源合并不同窗口的下载，各调用方独立取消。

`chat-media-import-v1` 是 `account-storage-v1` 之后的追加迁移。导入前登记资源身份，业务引用与导入完成同事务提交；失败和启动恢复由全部业务引用检查后回收。既有基线数据库原地升级，不清空数据或重新生成密钥。使用条件、本次测试与未执行验收见[分阶段修复记录](../../Documentation/Engineering/2026-10-06-staged-repairs.md)。
