# 朋友圈契约 v1

权威字段源为 [azurefish.proto](../Protos/azurefish.proto)。客户端只同步副本，在构建时生成 Swift 类型。接口沿用 Bearer、HTTP＋Protobuf、no-store、会话刷新和稳定 ApiError；正常业务 HTTPS，现有回环环境仅虚构账号。

## 路由

以下均为 POST，前缀 `/v1/moments`，成功返回 200。

| 路径 | 请求 | 响应 |
| --- | --- | --- |
| `/list` | MomentsListRequest | MomentsListResponse |
| `/get` | MomentsGetRequest | MomentsGetResponse |
| `/publish` | MomentPublishRequest | MomentMutationResult |
| `/result` | MomentIdentityRequest | MomentPost |
| `/delete`、`/like` | MomentMutationRequest | MomentMutationResult |
| `/comments/create` | MomentCommentRequest | MomentMutationResult |
| `/comments/delete` | MomentDeleteCommentRequest | MomentMutationResult |
| `/album` | MomentAlbumRequest | MomentAlbum |
| `/cover` | MomentCoverRequest | MomentMutationResult |

列表默认 20、最多 50 条，固定发布序号上界；签名游标绑定查看者和指定相册，不接受跨账号或跨相册使用。删除墓碑也占扫描位置，因此空页可带 has_more。响应按 3 MiB 内容预算提前分页，不跳过未返回动态。`get` 最多 100 个 ID，返回当前投影及 unavailable_ids；不存在、删除和无权限不区分。过大批量返回 PAYLOAD_TOO_LARGE，客户端拆分批量后重试。

## 内容及幂等

文字最多 2,000 Character／64 KiB；图片 0～9 张，不允许空动态及重复资产。评论最多 500 Character／16 KiB，沿用 Validation.text。静态图片通过现有媒体服务校验。当前开发容量上限为每动态 200 次评论身份（删除后身份仍保留以防复活）、500 个点赞，写入投影最多 2 MiB；超限返回 MOMENT_INTERACTION_LIMIT。

post_id 为稳定客户端 UUID；原发布内容指纹不变时可使用新操作身份对账，同 ID 不同内容返回 MOMENT_ID_CONFLICT。所有写操作带 operation_id，以账号和操作类型绑定完整原请求指纹，不受 token 刷新影响。幂等记录只保存动态／相册身份，重放按当前权限返回当前内容。删除动态保留清空正文、图片、互动后的墓碑；删除评论保留摘要身份，旧评论重试不能复活。

点赞接口提交 liked 最终状态。封面采用 expected_revision 防止跨窗口覆盖。发布／互动／删除、媒体引用与幂等身份同事务提交。每账号写每分钟 120 次，继续受现有共享开发 IP 限流保护。

## 当前权限

所有读取、互动和下载要求本人或双方均保留且均未拉黑的好友关系；用户已删除时不可见。作者看全部互动，其他用户仅看本人及当前双向好友的互动。回复对象必须是当前可见评论参与者或作者；读取时同时过滤回复者及被回复者。公开资料读取当前版本，不暴露备注或私有关系设置。

`/result` 仅作者查询，返回当前动态或删除墓碑。删除账号立即使动态不可访问，恢复清理随后移除正文、相册、互动及朋友圈媒体引用；其他参与者仍有权访问的聊天内容遵循原账号删除规则。

## 媒体用途及迁移

MediaCreateRequest 新增 purpose：空值／chat 保留原行为；moments_post 接受 image／video，moments_cover 只接受 image；两者 conversation_id 必须为空。旧 media_assets 通过新增迁移保留全部 ID 与聊天引用，将 conversation_id 改为可空并填充 purpose=chat；在事务内重建并验证所有外键后提交。禁止破坏性回滚为旧表。

下载授权新增 moments_target_id：moments_post 对应动态 UUID，moments_cover 对应相册所有者 UUID。资源必须被该目标当前引用；每次请求及每个输出分块再次验证 Bearer、generation、引用和当前好友关系。替换封面、删除动态或拉黑后，旧授权不能继续读取新分块。已下载内容无法远程收回。

朋友圈使用独立引用表，不建立聊天会话。取消、过期、回收及账号清理同时检查聊天和朋友圈引用；未引用和最后引用移除的 24 小时回收规则保持不变。现有聊天路由、资源校验、配额、加密和处理工作进程共用。

## 错误处理

| code | 行为 |
| --- | --- |
| MOMENT_UNAVAILABLE | 移除失效内容，中性提示，不区分无权限或不存在 |
| MOMENT_OWNER_REQUIRED | 拒绝删除他人内容 |
| MOMENT_VERSION_CONFLICT | 刷新封面版本，保留本地照片，不静默覆盖 |
| MOMENT_ID_CONFLICT／OPERATION_CONFLICT | 停止改写原身份，核对原内容 |
| MOMENT_INTERACTION_LIMIT | 显示容量限制，不盲目重试 |
| VALIDATION_FAILED | 保留输入，按字段校验 |
| INVALID_CURSOR | 重开分页，禁止套用其他账号／相册游标 |

媒体错误和上传恢复沿用[媒体契约](media-contract.md)。运行证据见[客户端验证记录](../../Documentation/Design/Moments/validation.md)。

## 视频扩展

`MomentPost.video`（11）和 `MomentPublishRequest.video_asset_id`（5）追加字段，保留旧图片字段和编号。正文、图片、视频至少存在一项；视频与 `asset_ids` 互斥。视频必须属于当前用户、用途为 moments_post、没有会话绑定且处理就绪。媒体处理器使用实际解码元数据校验有效画面、封面及 1～60000 ms 时长；发布事务再次检查时长和封面。`MediaCapabilities.moments_video_max_duration_ms`（32）返回 60000，文件上限沿用 512 MiB；聊天视频规则不变。字段约束拒绝返回 VALIDATION_FAILED，解码或处理约束拒绝使用现有 INVALID_MEDIA。

原件和派生 cover 使用相同动态引用及下载授权。视频写入、引用与幂等记录仍同事务提交；删除墓碑清除 video，旧发布结果不得复活视频。服务端不接收客户端声称的时长作为权威信息。客户端发布前查询能力，旧服务端未开放时不上传朋友圈视频。

视频本轮验证：`swift test -j 4` 共 71 项，66 通过、5 条件跳过；含真实 MP4 分块上传和三账号授权回归。iPad 客户端真实回环发布、重复下载和删除联调通过，结果及未执行项见[客户端验证记录](../../Documentation/Design/Moments/validation.md#视频发布与播放2026-10-11)。本轮同时修复工作文件扩展名过滤，保留 mp4／m4a 中的数字。
