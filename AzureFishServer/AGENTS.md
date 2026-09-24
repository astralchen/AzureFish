# AzureFishServer 开发约定

- 独立 Swift 6＋Vapor 服务端；AzureFish iOS 客户端位于上级仓库的 `AzureFish/`，服务端在本目录独立构建。数据库和构建不依赖客户端目录。
- `Protos/azurefish.proto` 是唯一权威网络消息来源。变更后执行 `Scripts/generate-protocol.sh`，同步生成产物、版本清单及协议说明；不要手改生成的 Swift。
- 四空格缩进，按行为契约编写中文 DocC 注释。业务错误返回稳定 code／field，由客户端本地化。
- 首期只支持虚构数据、回环 HTTP、单实例。不得通过放宽监听、关闭证书校验或明文持久化来绕过真实账号上线门槛。
- 保持密码异步哈希、会话绝对期限、刷新重放撤销提交、写请求幂等及资料版本检查。不得将密码、令牌、密钥和敏感正文写入日志或 Git。
- 保留 `.local` 中的数据和原密钥；缺失／错误密钥停止，不自动重建库。详细限制见 `Documentation/security.md`。
- 行为变更补 Swift Testing 回归，执行 `swift test -j 4`；HTTP 联调使用 `Scripts/smoke-test.py`，不得连接真实账号环境。同步记录本次结果及未验证项，不能将编译当作运行验证。
- Git 提交和 PR 使用中文。不要自动提交、发布或修改客户端 UI；客户端接入需按明确任务范围实施。
