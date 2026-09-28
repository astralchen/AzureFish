# 账号安全与头像（本机虚构账号）

2026-09-28。权威字段为 `Protos/azurefish.proto`，保持原账号与 IM 数据增量迁移。

| 接口 | 输入／输出 | 行为 |
| --- | --- | --- |
| POST /v1/auth/reauthenticate | ReauthenticateRequest / ReauthenticateResponse | 当前密码验证，凭据五分钟有效，绑定会话和动作 |
| GET /v1/me/security | 无正文 / AccountSecurityStatus | 密码方式、仍由当前账号管理的群 |
| POST /v1/me/security/change_password | AccountSecurityRequest / EmptyResponse | 修改密码、撤销全部会话，200 |
| POST /v1/me/security/logout_all | AccountSecurityRequest / EmptyResponse | 撤销全部会话，200 |
| POST /v1/me/security/delete_account | AccountSecurityRequest / EmptyResponse | 停用账号并持久化清理任务，202 |
| POST /v1/me/avatar | UpdateAvatarRequest / UserProfile | 版本检查，JPEG 更新或空字节恢复默认，200 |
| GET /v1/users/:user/avatar | 无正文 / AvatarResponse | 需登录及本人／已有关系／共同会话身份，200 |

全部响应为 Protobuf，包括头像字节；缓存控制为 no-store。头像仅接受 512×512 JPEG、最多 256 KiB，头像请求上限 260 KiB。资料增加可选头像标识，公共资料增加注销标记；历史客户端未知字段保持兼容。

敏感动作限定为 `change_password`、`logout_all`、`delete_account`；再次认证只保存令牌摘要，业务操作成功时同事务消费。`REAUTH_REQUIRED` 表示过期、已消费、会话或用途不匹配。客户端保留同一操作 ID 和序列化字节重试。删除请求另存独立 Keychain 恢复包供进程重启使用，不包含密码或刷新令牌，十分钟后失效；已确认的本机清理标记不受此窗口影响。恢复校验原访问凭据对应的会话、动作和请求摘要；即使访问凭据刚过期或会话已撤销，也只能读取十分钟恢复窗口内的既有结果，不能执行新动作。

删除账号先检查群主身份，未转让／解散时返回 `OWNER_TRANSFER_REQUIRED`。停用、清空个人资料／头像、撤销会话和删除任务日志先提交；后续清理失败不撤回已受理结果，启动时继续执行。退出群成员关系、清除私有快照／同步事件、旧登录及资料响应和关系留言，未被消息引用的上传进入既有到期回收机制；保留其他成员历史及其有效媒体引用。保留不可逆账号摘要和最小身份墓碑，避免旧账号名重新注册冒用。读取者用注销标记本地化身份；已退群成员的关闭会话快照同样更新注销标记，历史访问区间保持不变。

当前只支持本机虚构数据，既有生产 HTTPS、托管密钥、备份恢复和分布式限流门槛仍适用。不得将本次本机结果描述为真实账号上线验收。
