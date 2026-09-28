# IM 媒体后台契约 v1

本实现面向单实例 macOS、虚构账号和回环网络。客户端上传队列、加密缓存及原版聊天 UI 的接入状态见[本次记录](../../Documentation/Design/Chat/original-ui-restoration.md)。权威字段见 [azurefish.proto](../Protos/azurefish.proto)，消息受众和同步沿用 [IM 契约](im-contract.md)。验证状态见 [实施记录](validation.md)。

## 资源闭环

客户端依次执行：创建附件 → 上传缺失分块 → complete → 查询 ready → 发送消息。上传完成不等于消息已发送。网络失败保留 operation_id、asset_id、upload_id、消息身份和请求原字节；永久失败保留草稿。取消上传不撤回已经接受的消息。

| 方法与路径 | 请求／响应 | 行为 |
| --- | --- | --- |
| GET `/v1/media/capabilities` | 无／MediaCapabilities | Bearer 鉴权后返回限额及工作进程可用性 |
| POST `/v1/media/assets/create` | MediaCreateRequest／MediaAssetStatus | 绑定上传者和活跃会话，预留容量 |
| POST `/v1/media/assets/status` | MediaAssetRequest／MediaAssetStatus | 仅上传者查询，返回角色、上传身份及升序完成分块 |
| PUT `/v1/media/uploads/{upload_id}/parts/{index}` | 二进制／MediaPartResponse | `application/octet-stream`，`X-Content-SHA256` 小写 SHA-256 |
| POST `/v1/media/assets/complete` | MediaAssetMutation／MediaAssetStatus | 检查分块齐全，持久化异步任务 |
| POST `/v1/media/assets/cancel` | MediaAssetMutation／MediaAssetStatus | 未被消息引用时取消并排队即时回收 |
| POST `/v1/media/resources/authorize` | MediaAuthorizeRequest／MediaDownloadGrant | 签发 5 分钟下载授权 |
| GET `/v1/media/resources/{resource_id}/content` | 无／二进制 | Bearer 与 `X-Media-Grant` 双重校验，支持单段 Range |

控制接口 `Content-Type: application/protobuf`；字节不进入消息、WS 或 Protobuf。成功通常为 200，Range 为 206。所有响应 no-store，错误使用既有 ApiError 和 request_id。文件名仅展示，禁止路径分隔、控制字符、`.`、`..`，最多 255 UTF-8 字节；磁盘路径不外泄。文件附件强制下载为 application/octet-stream，不执行或解压。

创建／完成／取消 operation_id 使用全局唯一表，作用域绑定操作种类和账号。同账号重新登录可恢复；原请求指纹不匹配返回 OPERATION_CONFLICT。幂等结果只保存附件身份，每次重试返回当前状态，删除墓碑不会变回 ready。分块固定 4 MiB，最后一块按声明长度计算，编号从 0 起，支持乱序。同编号同摘要且实际内容验证一致时成功；不同内容 PART_CONFLICT；同编号正在传输 PART_BUSY。

## 类型和内容组合

| 附件 kind | 原件约束 | 原生处理 |
| --- | --- | --- |
| image | ≤25 MiB、≤100 MP | JPEG、PNG、HEIC／HEIF、GIF、WebP、TIFF；静态 JPEG 缩略图 |
| video | ≤512 MiB | MP4／QuickTime，生成封面，不转码 |
| audio | ≤20 MiB、1～120 秒 | MP4 音频、CAF、WAV；60 点归一化波形，不转写 |
| file | ≤512 MiB | 仅完整性检查，下载原件 |
| live_photo | 照片 ≤25 MiB、配对视频 ≤512 MiB | 必须 original＋paired_video，系统验证最终完整配对结果 |

普通附件只有 original。图片／Live Photo 派生 thumbnail，视频派生 cover，均为最长边 1280 的 JPEG；预览不复制原件定位元数据。原件字节和原有元数据不变。实际解码类型必须匹配声明 MIME。Animated 图片仍使用 image，权威 animated 标识来自解码结果；保留动画原件、只生成静态缩略图。

消息 schema 仍为 1；在已有编号后追加 IMSendRequest.asset_ids 和 IMMessage.assets。text 支持 IM 契约中的语义格式，link 支持原始 HTTP／HTTPS URL，两者均不能带附件；media_group 的 text 为空，包含有序且不重复的 1～20 个 image／video／live_photo，原件合计 ≤1 GiB；audio／file 各恰好一个对应附件。全部 ready、同一上传者、同一会话才可提交。消息、序号、事件、附件引用和幂等结果同事务提交。旧客户端继续同步消息信封，将未知类型显示为占位。

## 状态、任务与生命周期

状态流：uploading → queued → processing → ready；验证或工作进程失败进入 failed。未引用的上传／处理中／失败附件从创建起 24 小时过期，ready 从就绪起 24 小时过期。有效消息引用设置无过期；撤回最后引用后延迟 24 小时回收。同一上传者可在原会话重复引用就绪附件。

处理队列持久化且一次一个任务；macOS 独立 AzureFishMediaWorker 使用 ImageIO／AVFoundation／Photos，子进程运行上限 120 秒。超时、崩溃、缺少工作进程、类型不符和畸形数据分别返回明确 failure_code。重启重新排队中断任务；正常关闭停止子进程，启动清理遗留临时明文。服务程序与工作进程默认同目录，开发启动脚本会构建两者；测试可通过 AZUREFISH_MEDIA_WORKER 指定受信任的本机可执行文件。

下载 draft_preview 仅适用于从未发布过的 ready 附件所有者；首次发布后必须 message_view＋具体 message_uuid。下载权限使用消息固定受众和群成员历史区间，不能通过知道资源 ID 绕过历史边界。授权绑定账号、session、资源、用途、消息和附件 generation，每次请求及每个输出分块重新校验 Bearer 和消息权限。刷新 Bearer 可沿用同 session 授权；重新登录 session 改变须重新申请授权。

撤回事务清空消息 assets 并移除对应引用；旧发送结果和旧事件按当前消息物化，不能复活附件。旧授权在下一请求／下一个分块前失败；当前已进入输出的分块与已下载字节不能远程收回。其他有效引用不受影响。

HEAD 使用相同授权返回原件／预览的响应头和完整长度，不发送字节、不保留传输租约，并忽略 Range。Range 接受 bytes=start-end、bytes=start-、bytes=-suffix，不接受多段。If-Range 强 ETag 不匹配时返回全量 200；有效单段返回 206 和 Content-Range，不可满足返回 416 与 `bytes */长度`，语法错误返回 400。下载原件完成必须由客户端核对完整长度与 SHA-256；授权过期重新申请，不改变资源身份。依据 [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html)。

回收每 5 分钟检查过期附件；显式取消进入即时队列。先关闭新访问并等待已有 IO 租约退出，再删除文件，最后清除包装密钥、分块和私密元数据并释放预留。文件删除失败保留密钥和配额以便重试。资源／附件身份留最小墓碑；启动对账清除未被数据库引用的密文。仍被有效消息引用的文件没有自动过期时间。

## 容量与错误恢复

每账号 5 GiB、实例 20 GiB，包含上传预留、GCM 封装、清单和预览预算。非文件附件预留额外 8 MiB 派生预算；创建时检查可用磁盘和未完成预留，空间不足明确拒绝。每账号 4 个、实例 16 个并发字节请求；分块 IO、完整散列和解码均在数据库 gate 外运行。字节路由独立采用开发 IP 每分钟 600 次，账号／控制接口沿用原限制。

| 错误码 | 动作 |
| --- | --- |
| UPLOAD_INCOMPLETE | 查询完成分块，补传缺失编号 |
| PART_BUSY／MEDIA_CONCURRENCY_LIMIT | 退避并减少并发 |
| PART_CONFLICT／OPERATION_CONFLICT | 停止该身份重试，对账原请求 |
| PART_SIZE_MISMATCH／CONTENT_DIGEST_MISMATCH | 检查原件与分块；不得把损坏上传标为完成 |
| INVALID_MEDIA／MEDIA_TYPE_MISMATCH | 永久失败，保留草稿并更换附件 |
| PROCESSOR_UNAVAILABLE／PROCESSOR_FAILED／PROCESSING_TIMEOUT | 明确失败，排查部署／资源；创建新附件重试 |
| MEDIA_NOT_READY／MEDIA_NOT_AVAILABLE／MEDIA_NOT_FOUND | 刷新状态和消息权限，不盲目重发消息 |
| MEDIA_IN_USE | 取消不能替代撤回消息 |
| MEDIA_QUOTA_EXCEEDED／MEDIA_STORAGE_UNAVAILABLE | 释放未使用资源或修复存储后重试 |
| MEDIA_INTEGRITY_FAILED／MEDIA_KEY_UNAVAILABLE | 停止读取并恢复正确密文／密钥，不生成替代密钥 |
| MEDIA_GRANT_EXPIRED／MEDIA_GRANT_INVALID | 凭有效 Bearer 重新授权；禁止持久化到消息 |

病毒扫描、内容审核、链接抓取、头像、跨会话转发、对象存储、Linux 和生产 HTTPS/WSS 不在本实现范围。系统 Live Photo 验证使用 [PHLivePhoto 请求接口](https://developer.apple.com/documentation/photos/phlivephoto/request%28withresourcefileurls%3Aplaceholderimage%3Atargetsize%3Acontentmode%3Aresulthandler%3A%29)，忽略 degraded 回调，只接受最终完整结果。
