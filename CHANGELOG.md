# CHANGELOG

两个 SDK（Flutter `guokit_im`、PHP `guokit/im`）共用仓库版本号。

## v0.5.0 — 2026-11-24

会话置顶、免打扰、清空记录、删除会话（都只影响本人，多端同步）。需要 IM 服务端支持会话设置接口（bf-go 下一版），旧服务端上新方法抛 `ImApiException`，其余功能不受影响。

- **Flutter**：新增 `setPinned` / `setMuted` / `clearConversation` / `deleteConversation`；`ImConversation` 加 `pinnedAt` / `pinned` / `muted` / `clearSeq`；会话快照置顶在前；总未读不计免打扰会话；处理 `conversation_changed` 推送，对账时调 `GET /conversations/changes` 补齐离线期间别的设备的改动；清空 / 删除后旧消息不再补拉、不复现。本地库 v1 → v2 自动升级
- **不兼容**：自己实现 `ImStore`（桌面端注入）的要补 `clearMessages`、`deleteConversation`、`changesCursor`、`setChangesCursor`，并按接口注释更新会话合并、排序、总未读规则
- **PHP**：新增 `conversationSettings` / `setConversationSettings` / `clearConversation` / `deleteConversation`（按对方定位，客服会话对方写 `@cs`）；README 演示 after_send 的 `to_muted`（为 true 时不推离线）
- 接入文档新增 §4.9 服务端会话设置、§5.10 / §5.11 客户端接口；after_send 加 `to_muted`，`to_unread_total` 与 `/unread` 不计免打扰会话；Skill、`llms-full.txt` 同步

## v0.4.1 — 2026-11-23

首个接入方（大景象）实读 v0.1.0 源码时提的 4 处，PHP SDK 代码不变。

- **Flutter 新增 `pendingTo(peerId)`**：取发给对方的未确认消息（发送中 / 失败 / 被拒收）。会话建立前第一条就发失败时，`conversationWith` 为 null、`messages` 取不到它，聊天页现在可以用它显示并重发
- **`imageUrl` 文档如实描述**：未确认的上传图返回上传时的临时链接（约 24 小时有效），按路径发的图优先用 `localPath`；行为不变，原注释误写成返回 null
- **接入文档**：§4.2 写明批量导入遇到已存在用户只覆盖昵称与头像、不改封禁状态、可重复执行；§5.7 写明客户端与服务端黑名单是同一份名单

## v0.4.0 — 2026-11-23

只改了 PHP SDK 与文档，Flutter SDK 与 v0.3.0 相同。

- **PHP `onlineStatus(array $userIds)`**：批量查询在线状态（1–100 个），返回 `[user_id => bool]`；不存在、被封禁的用户为 false
- **回调 `user_state`**：`CallbackEvent` 的事件名多了 `user_state`（用户上下线，IM 设置里打开才推）；README 写明不认识的事件也回 `Callback::ack()`
- 接入文档新增 §4.8 查询在线状态、§8.4 `user_state` 回调；Agent Skill 与 `llms-full.txt` 同步

## v0.3.0 — 2026-11-23

只改了 Flutter SDK 与文档，PHP SDK 与 v0.1.0 相同。

- **业务卡片**：接入文档新增 §5.9「业务卡片 `im_card`」——订单、商品、文章这类 custom 消息在 `data.im_card` 里带标准卡片外壳（`title` 必填；`kind`、`subtitle`、`image`、最多 6 行 `fields` 快照；链接按端分 `web_link` / `app_link` / `mp_path` + `mp_appid`），服务端发送时校验、不合规范整条拒收（`VALIDATION`）。OpenAPI 新增 `ImCard`
- **Flutter**：新增 `ImCard` / `ImCardField` 模型与 `ImMessage.card`（非 custom、没带卡片或缺 `title` 时为 null）；`sendCustom` 不变，把 `im_card` 放进 `data` 即可。README 常见问题补「业务卡片怎么发、怎么显示」
- Agent Skill 与 `llms.txt` 补业务卡片说明

## v0.2.0 — 2026-11-23

只改了 Flutter SDK，PHP SDK 与 v0.1.0 相同。

- **新增客服接口**：`csState()` 取平台客服的接待状态（`ImCsState`：状态、接待 id、排队名次），
  `rateCs(sessionId, rating, {comment})` 评价一次已结束的接待。走 SDK 自管的令牌与 401 换令牌重试，
  不必再在 `tokenProvider` 里自留令牌。评分不在 1–5、评语去首尾空白后超过 200 字直接抛 `ArgumentError`。
  README 写明状态条与评价卡片的做法
- **修复**：换令牌重试用完、停在 disconnected 后，再调 `login(同一用户)` 恢复不了（拿缓存里被拒的令牌反复连，
  不再调 `tokenProvider`）。现在会重新取令牌并连上，与 README「再调一次 login 即重连」一致

## v0.1.0 — 2026-11-21

首个版本：接入文档、OpenAPI 3.1 规范、`llms.txt` 与 Agent Skill（`guokit-im`）；Flutter 客户端 SDK
（令牌自动续、断线对账补拉、本地消息库、发送三态与重发、图片链接过期重拉）；PHP 服务端 SDK
（用户、令牌、封禁、黑名单、代发、审计历史、回调验签）。
