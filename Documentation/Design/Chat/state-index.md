# 页面与状态索引

2026-09-28 新增：[好友通过双向聊天提醒、六个状态及四语言文案](friendship-notice.md)。


## 全屏会话列表更新

`list.empty`、`list.syncing`、`list.failed` 已按全屏列表更新；新增搜索无结果、无缓存失败、深色和 iPad 空状态。节点与 PNG 对应关系见 [专项索引](conversation-list-empty.md#工程设计图与可编辑源)。

## 撤回与重新编辑新增状态

原 `chat.revoked` 已更新为本人文本撤回的三分钟编辑入口；实现及验证见 [专项说明](revoke-reedit.md)。

| 状态身份 | 页面 | Figma | 工程图片 |
| --- | --- | --- | --- |
| `chat.revoked.other` | 对方撤回 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=116-1961) | [图片](Previews/revoked-other.png) |
| `chat.revoked.media` | 媒体撤回 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=116-1994) | [图片](Previews/revoked-media.png) |
| `chat.revoked.expired` | 重新编辑已过期 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=116-2027) | [图片](Previews/revoked-expired.png) |
| `chat.reedit.draft` | 已恢复到输入栏 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=116-2060) | [图片](Previews/reedit-draft.png) |
| `chat.reedit.existing` | 已有文字草稿 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=116-2099) | [图片](Previews/reedit-existing.png) |
| `chat.reedit.confirm` | 替换草稿确认 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=116-2138) | [图片](Previews/reedit-confirm.png) |
| `chat.revoked.group` | 群成员撤回 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=119-1992) | [图片](Previews/revoked-group.png) |
| `chat.revoked.dark` | 深色撤回提示 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=119-2021) | [图片](Previews/revoked-dark.png) |

## 通讯录与既有状态

通讯录、好友与导航栏新增状态如下；聊天内容样式按 [工程对照](engineering-alignment.md) 更新，工程内图片见 [画廊](Previews/index.html)。

| 状态身份 | 页面 | Figma | 预设原型 |
| --- | --- | --- | --- |
| `contacts.list` | 通讯录 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=84-1805) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=84-1805&starting-point-node-id=84%3A1805) |
| `contacts.requests` | 新的朋友 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=84-1861) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=84-1861&starting-point-node-id=84%3A1861) |
| `contacts.lookup` | 添加好友 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=84-1896) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=84-1896&starting-point-node-id=84%3A1896) |
| `contacts.result` | 查询结果 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=84-1916) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=84-1916&starting-point-node-id=84%3A1916) |
| `contacts.pending` | 申请待确认 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=84-1936) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=84-1936&starting-point-node-id=84%3A1936) |
| `contacts.incoming` | 收到申请 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=84-1954) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=84-1954&starting-point-node-id=84%3A1954) |
| `contacts.friend` | 好友详情 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=84-1974) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=84-1974&starting-point-node-id=84%3A1974) |
| `contacts.delete` | 删除好友 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=84-1994) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=84-1994&starting-point-node-id=84%3A1994) |
| `contacts.empty` | 空通讯录 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=84-2012) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=84-2012&starting-point-node-id=84%3A2012) |
| `contacts.changed` | 关系已变化 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=84-2039) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=84-2039&starting-point-node-id=84%3A2039) |
| `contacts.accepted` | 已接受好友 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=86-1839) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=86-1839&starting-point-node-id=86%3A1839) |
| `contacts.offline` | 离线缓存 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=86-1869) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=86-1869&starting-point-node-id=86%3A1869) |
| `contacts.loading` | 首次同步 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=86-1927) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=86-1927&starting-point-node-id=86%3A1927) |
| `contacts.failed` | 同步失败 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=86-1947) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=86-1947&starting-point-node-id=86%3A1947) |
| `contacts.unknown` | 确认申请结果 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=86-1967) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=86-1967&starting-point-node-id=86%3A1967) |
| `contacts.accepted.chat` | 旧示例；新规则见上方双向提醒 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=99-1848) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=99-1848&starting-point-node-id=99%3A1848) |
| `contacts.accepted.delete` | 新好友删除确认 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=99-1889) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=99-1889&starting-point-node-id=99%3A1889) |
| `list.actions` | 导航栏发起聊天菜单 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=87-1898) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=87-1898&starting-point-node-id=87%3A1898) |

> 所有节点是本轮新增可编辑 Figma Frame。原型是虚构数据的预设路径；自动阶段变化不代表真实服务器保证。各状态可从原型流程列表独立打开。四语言／窗口适配稿属于静态比较，不伪装为真实全局切换。

[从设计导览开始](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=50-1805&starting-point-node-id=50%3A1805)。

| 状态身份 | 页面 | Figma | 预设原型 |
| --- | --- | --- | --- |
| `list.default` | 聊天 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-1805) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-1805&starting-point-node-id=53%3A1805) |
| `list.empty` | 聊天 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-1860) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-1860&starting-point-node-id=53%3A1860) |
| `list.syncing` | 聊天 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-1889) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-1889&starting-point-node-id=53%3A1889) |
| `list.offline` | 聊天 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-1946) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-1946&starting-point-node-id=53%3A1946) |
| `list.failed` | 聊天 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2003) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2003&starting-point-node-id=53%3A2003) |
| `lookup.empty` | 发起聊天 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2060) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2060&starting-point-node-id=53%3A2060) |
| `lookup.result` | 发起聊天 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2081) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2081&starting-point-node-id=53%3A2081) |
| `lookup.missing` | 发起聊天 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2109) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2109&starting-point-node-id=53%3A2109) |
| `lookup.self` | 发起聊天 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2132) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2132&starting-point-node-id=53%3A2132) |
| `lookup.limited` | 发起聊天 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2155) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2155&starting-point-node-id=53%3A2155) |
| `chat.empty` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2178) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2178&starting-point-node-id=53%3A2178) |
| `chat.sending` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2201) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2201&starting-point-node-id=53%3A2201) |
| `chat.sent` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2229) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2229&starting-point-node-id=53%3A2229) |
| `chat.delivered` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2257) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2257&starting-point-node-id=53%3A2257) |
| `chat.read` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2285) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2285&starting-point-node-id=53%3A2285) |
| `chat.waiting` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2313) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2313&starting-point-node-id=53%3A2313) |
| `chat.confirming` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2343) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2343&starting-point-node-id=53%3A2343) |
| `chat.failed` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2373) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2373&starting-point-node-id=53%3A2373) |
| `chat.history` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2403) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2403&starting-point-node-id=53%3A2403) |
| `chat.group` | 周末小队 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2433) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2433&starting-point-node-id=53%3A2433) |
| `receipts.summary` | 消息回执 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2464) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2464&starting-point-node-id=53%3A2464) |
| `chat.menu` | 消息操作 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2500) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2500&starting-point-node-id=53%3A2500) |
| `revoke.confirm` | 撤回消息 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2534) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2534&starting-point-node-id=53%3A2534) |
| `chat.revoked` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2555) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2555&starting-point-node-id=53%3A2555) |
| `revoke.expired` | 无法撤回 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2583) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2583&starting-point-node-id=53%3A2583) |
| `delete.confirm` | 本机删除 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2602) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2602&starting-point-node-id=53%3A2602) |
| `chat.deleted` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2623) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2623&starting-point-node-id=53%3A2623) |
| `chat.details` | 聊天详情 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2644) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2644&starting-point-node-id=53%3A2644) |
| `clear.confirm` | 清空本机记录 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2663) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2663&starting-point-node-id=53%3A2663) |
| `chat.unknown` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=53-2684) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=53-2684&starting-point-node-id=53%3A2684) |
| `media.draft` | 附件草稿 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-1805) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-1805&starting-point-node-id=54%3A1805) |
| `media.reorder` | 附件顺序 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-1845) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-1845&starting-point-node-id=54%3A1845) |
| `media.reordered` | 附件顺序 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-1878) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-1878&starting-point-node-id=54%3A1878) |
| `media.limit` | 附件草稿 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-1911) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-1911&starting-point-node-id=54%3A1911) |
| `media.uploading` | 正在发送 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-1953) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-1953&starting-point-node-id=54%3A1953) |
| `media.processing` | 正在发送 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-1981) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-1981&starting-point-node-id=54%3A1981) |
| `media.ready` | 正在发送 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2009) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2009&starting-point-node-id=54%3A2009) |
| `media.failed` | 发送遇到问题 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2035) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2035&starting-point-node-id=54%3A2035) |
| `media.cancel` | 取消发送 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2063) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2063&starting-point-node-id=54%3A2063) |
| `media.sent` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2084) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2084&starting-point-node-id=54%3A2084) |
| `media.viewer` | 照片 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2113) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2113&starting-point-node-id=54%3A2113) |
| `media.downloading` | 照片 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2140) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2140&starting-point-node-id=54%3A2140) |
| `media.complete` | 照片 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2169) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2169&starting-point-node-id=54%3A2169) |
| `media.live` | Live Photo | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2198) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2198&starting-point-node-id=54%3A2198) |
| `media.video` | 视频 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2225) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2225&starting-point-node-id=54%3A2225) |
| `media.animated` | 动图 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2252) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2252&starting-point-node-id=54%3A2252) |
| `media.unavailable` | 媒体不可用 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2279) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2279&starting-point-node-id=54%3A2279) |
| `media.saved` | 保存完成 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2302) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2302&starting-point-node-id=54%3A2302) |
| `media.share` | 分享 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2321) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2321&starting-point-node-id=54%3A2321) |
| `media.permission` | 无法保存 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2340) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2340&starting-point-node-id=54%3A2340) |
| `file.available` | 文件 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2359) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2359&starting-point-node-id=54%3A2359) |
| `file.complete` | 文件 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2379) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2379&starting-point-node-id=54%3A2379) |
| `file.saved` | 保存文件 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2401) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2401&starting-point-node-id=54%3A2401) |
| `file.integrity` | 文件 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2420) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2420&starting-point-node-id=54%3A2420) |
| `voice.recording` | 录制语音 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2442) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2442&starting-point-node-id=54%3A2442) |
| `voice.preview` | 试听语音 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2494) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2494&starting-point-node-id=54%3A2494) |
| `voice.limit` | 试听语音 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2546) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2546&starting-point-node-id=54%3A2546) |
| `voice.sent` | 语音消息 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2600) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2600&starting-point-node-id=54%3A2600) |
| `voice.permission` | 录音权限 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=54-2652) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=54-2652&starting-point-node-id=54%3A2652) |
| `voice.paused` | 语音播放暂停 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=66-2001) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=66-2001&starting-point-node-id=66%3A2001) |
| `group.create` | 创建群聊 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-1805) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-1805&starting-point-node-id=55%3A1805) |
| `group.lookup` | 添加成员 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-1841) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-1841&starting-point-node-id=55%3A1841) |
| `group.create.failed` | 创建群聊 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-1869) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-1869&starting-point-node-id=55%3A1869) |
| `group.chat` | 周末小队 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-1907) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-1907&starting-point-node-id=55%3A1907) |
| `group.owner` | 群聊详情 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-1938) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-1938&starting-point-node-id=55%3A1938) |
| `group.member` | 群聊详情 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-1977) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-1977&starting-point-node-id=55%3A1977) |
| `group.rename` | 修改群名称 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2010) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2010&starting-point-node-id=55%3A2010) |
| `group.conflict` | 修改群名称 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2046) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2046&starting-point-node-id=55%3A2046) |
| `group.members` | 群成员 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2084) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2084&starting-point-node-id=55%3A2084) |
| `group.remove.confirm` | 移除成员 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2122) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2122&starting-point-node-id=55%3A2122) |
| `group.members.updated` | 群成员 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2143) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2143&starting-point-node-id=55%3A2143) |
| `group.transfer` | 转让群主 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2162) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2162&starting-point-node-id=55%3A2162) |
| `group.transfer.confirm` | 转让群主 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2192) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2192&starting-point-node-id=55%3A2192) |
| `group.leave.confirm` | 退出群聊 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2213) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2213&starting-point-node-id=55%3A2213) |
| `group.left` | 周末小队 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2234) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2234&starting-point-node-id=55%3A2234) |
| `group.removed` | 周末小队 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2269) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2269&starting-point-node-id=55%3A2269) |
| `group.dissolve.confirm` | 解散群聊 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2304) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2304&starting-point-node-id=55%3A2304) |
| `group.dissolved` | 周末小队 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2325) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2325&starting-point-node-id=55%3A2325) |
| `group.rejoined` | 周末小队 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2360) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2360&starting-point-node-id=55%3A2360) |
| `group.owner.leave` | 退出群聊 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2393) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2393&starting-point-node-id=55%3A2393) |
| `draft.closed` | 保留的草稿 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2412) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2412&starting-point-node-id=55%3A2412) |
| `draft.copied` | 保留的草稿 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2435) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2435&starting-point-node-id=55%3A2435) |
| `draft.delete` | 删除草稿 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2454) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2454&starting-point-node-id=55%3A2454) |
| `group.receipts.summary` | 群消息回执 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=55-2475) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=55-2475&starting-point-node-id=55%3A2475) |
| `group.create.filled` | 创建群聊 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=59-1862) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=59-1862&starting-point-node-id=59%3A1862) |
| `group.remove.xu` | 移除成员 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=59-1898) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=59-1898&starting-point-node-id=59%3A1898) |
| `group.remove.he` | 移除成员 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=59-1919) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=59-1919&starting-point-node-id=59%3A1919) |
| `group.transfer.xu` | 转让群主 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=59-1940) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=59-1940&starting-point-node-id=59%3A1940) |
| `adapt.zh.light` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=60-1805) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=60-1805&starting-point-node-id=60%3A1805) |
| `adapt.zh.dark` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=60-1833) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=60-1833&starting-point-node-id=60%3A1833) |
| `adapt.hant` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=60-1861) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=60-1861&starting-point-node-id=60%3A1861) |
| `adapt.en` | Chats | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=60-1889) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=60-1889&starting-point-node-id=60%3A1889) |
| `adapt.ar` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=60-1944) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=60-1944&starting-point-node-id=60%3A1944) |
| `adapt.ar.dark` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=60-1972) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=60-1972&starting-point-node-id=60%3A1972) |
| `adapt.ar.media` | 附件草稿 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=60-2000) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=60-2000&starting-point-node-id=60%3A2000) |
| `adapt.ar.group` | 群聊详情 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=60-2040) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=60-2040&starting-point-node-id=60%3A2040) |
| `adapt.narrow` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=60-2079) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=60-2079&starting-point-node-id=60%3A2079) |
| `adapt.large` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=60-2107) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=60-2107&starting-point-node-id=60%3A2107) |
| `adapt.legacy` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=60-2135) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=60-2135&starting-point-node-id=60%3A2135) |
| `adapt.legacy.dark` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=60-2163) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=60-2163&starting-point-node-id=60%3A2163) |
| `adapt.reduceTransparency` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=60-2191) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=60-2191&starting-point-node-id=60%3A2191) |
| `adapt.ar.large` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=60-2219) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=60-2219&starting-point-node-id=60%3A2219) |
| `adapt.ipad` | iPad 双栏 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=61-1846) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=61-1846&starting-point-node-id=61%3A1846) |
| `adapt.compactWindow` | 林沐 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=61-1900) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=61-1900&starting-point-node-id=61%3A1900) |
| `adapt.darkList` | 聊天列表 · 深色 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=68-1866) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=68-1866&starting-point-node-id=68%3A1866) |
| `adapt.darkMedia` | 附件草稿 · 深色 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=68-1927) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=68-1927&starting-point-node-id=68%3A1927) |
| `adapt.darkGroup` | 群详情 · 深色 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=68-1967) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=68-1967&starting-point-node-id=68%3A1967) |
| `adapt.highContrast` | 增强对比度 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=68-2006) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=68-2006&starting-point-node-id=68%3A2006) |
| `group.member.xu` | 许宁成为群主 | [设计](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN?node-id=71-1873) | [打开](https://www.figma.com/proto/su1BAcMKAwW11bE2n2n9rN?node-id=71-1873&starting-point-node-id=71%3A1873) |
