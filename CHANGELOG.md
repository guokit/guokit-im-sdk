# CHANGELOG

三个 SDK（Flutter `guokit_im`、PHP `guokit/im`、JS `@guokit/im`）共用仓库版本号。

## v0.12.1 — 2026-11-25

修 Flutter SDK 换号串账号，**支持切换账号的 App 请尽快升级**。

- **Flutter**：同一个 `GuokitIm` 实例里 A 登出、B 登录，而 A 还有请求没返回时，A 的会话与消息会写进 B 的本地库，A 的消息可能以 B 的身份发出，A 迟到的被踢会把 B 踢下线。改为每次登录一整套、登出整套作废
- **Flutter** 行为变化：登出时还没返回的调用抛 `StateError`；登出时还在发的消息以 failed / `UNKNOWN` 完成、不发事件；`block` / `unblock` / `blocks` 要先登录（与其他方法一致）；开库、关库串行，没等 `logout()` 完成就 `login()` 的会等它收尾完；`login()` 没完成时又登出或登录别的用户，前一次正常返回但不会登录上；`resend` 别的账号的消息抛 `ArgumentError`
- 已经写错的本地数据不会自动清理，怀疑受影响的可以 `logout(clearCache: true)` 后重新登录
- **JS、PHP**：代码不变，JS 仍用 v0.12.0 的文件

## v0.12.0 — 2026-11-25

新增 JS 客户端 SDK。需要 IM 服务端 v1.17.0（文件与视频 v1.19.0，客服主体 v1.20.0），服务端不用改。

- **JS**：新增 `@guokit/im`，浏览器、uni-app（微信小程序 / H5 / App）、微信原生小程序共用一套内核，能力对齐 Flutter SDK。先从 GitHub Release 分发：npm 包 tgz、给 uni-app Vue3 的 ESM 单文件、给浏览器与微信原生小程序的单文件。只有内存缓存，没有 UI 组件
- **Flutter、PHP**：代码不变
- 接入文档 §6、§11 补 JS 与小程序；Skill、`llms.txt` 同步

## v0.11.0 — 2026-11-25

客服主体接待补全。需要 IM 服务端 v1.21.0。

- **PHP**：新增 `services`、`serviceAgents`、`replaceServiceAgents`、`serviceSessions`；回调事件加 `cs_session`（透传，`Callback` 不用改）
- **Flutter**：代码不变
- **注意**：主体 / 坐席不存在、主体停用的错误码由 `VALIDATION` 改为 `CS_SERVICE_NOT_FOUND`、`CS_AGENT_NOT_FOUND`、`CS_SERVICE_DISABLED`；`settings` 的文案给空串由「用站点设置」改为「不发」；开了 before_send 的站点会收到主体坐席的回复（`from` 为 `@cs:<主体标识>`），请放行或审核
- 工作台嵌入接口只加不改：`onReady`、`onError`、`open`、`back`，`onRemind` 多一个参数，`onTokenExpired` 会重复回调
- 接入文档 §10.11 大改，§8.1、§4.10 补充；OpenAPI、Skill、`llms-full.txt` 同步

## v0.10.0 — 2026-11-25

客服主体：一个站点里多个各自接待的客服（如每家门店一个）。需要 IM 服务端 v1.20.0；旧服务端上给主体发消息为用户不存在，`csState(serviceId)` 会给平台客服的状态，其余功能不受影响。**旧版 App 会先把主体会话当成普通单聊显示，请等用户都升级后再放出入口。**

- **Flutter**：新增 `csUserId` / `csServiceId`、`ImConversation.serviceId`，`csState` 加可选参数 `serviceId`；收到主体的第一条消息时会话类型正确为 `service`。只加不改
- **PHP**：新增 `upsertService`、`setServiceStatus`、`serviceSummary`、`importServices`、`upsertServiceAgent`、`removeServiceAgent`、`issueAgentToken`；README 的 after_send 示例改为排除全部客服
- 接入文档新增 §10.11 客服主体（维护接口、嵌入工作台、员工离线提醒），§10.7 挂件加 `service`；OpenAPI、Skill、`llms-full.txt` 同步

## v0.9.0 — 2026-11-25

文件与视频消息。需要 IM 服务端 v1.19.0；旧服务端上 `features()` 两项按 0，发送失败，其余功能不受影响。**要站点在「IM 设置」打开（默认关闭）；旧版 App 不认识这两种消息，会话预览是空白，请等用户都升级后再打开。**

- **Flutter**：新增 `sendFile` / `sendFileBytes`、`sendVideo` / `sendVideoBytes`、`fileUrl` / `videoUrl` / `videoCoverUrl`、上传进度 `onSendProgress`；`ImMessage` 加 `fileName` / `fileSize` / `videoDuration`，`ImFeatures` 加 `fileMaxMb` / `videoMaxMb`（缺省 0）；新错误码 `FILE_MISSING`、`VIDEO_MISSING`。只加不改
- **Flutter**：按路径发的文件、视频边读边传，不整个读进内存，上传最长等 5 分钟；视频封面先传，传过的重发不再传。选文件、转码、截封面、播放、下载由 App 自己做，示例 App 演示了选文件、选视频、播放与下载
- **PHP**：代码不变；文件、视频不能代发
- 接入文档改 §4.5、§5.1、§5.6（含类型与扩展名对照表）、§8.1、§9、§10；OpenAPI、Skill、`llms-full.txt` 同步。OpenAPI 的消息 `content` 由 `oneOf` 改为 `anyOf`：视频的字段包含了图片的字段，`oneOf` 会判成不合法

## v0.8.0 — 2026-11-25

撤回、语音消息、对方已读、正在输入。需要 IM 服务端 v1.17.0；旧服务端上 `recall` 抛 `ImApiException`、语音发送失败、`features()` 全部按没开启，其余功能不受影响。**撤回与对方已读要站点在「IM 设置」打开，请等用户都升级后再打开。**

- **Flutter**：新增 `recall`、`sendVoice` / `sendVoiceBytes` / `voiceUrl`、`sendTyping` / `onTyping`、`features`；`ImMessage` 加 `isRecalled` / `recalledBy` / `voiceDuration`，`ImConversation` 加 `peerReadSeq`（可空）；处理 `message_recalled`、`peer_read`、`typing` 推送，对账时调 `GET /recalls` 补齐离线期间的撤回；变成已撤回的消息经 `onMessageUpdated` 发出。本地库 v3 → v4 自动升级
- **Flutter**：`markRead` 每次登录后对每个会话至少上报一次，不再因为未读已是 0 就跳过（否则一键清未读之后再打开聊天，对方永远看不到已读）
- **不兼容**：自己实现 `ImStore`（桌面端注入）的要补 `recallsCursor`、`setRecallsCursor`、`setPeerReadSeq`，多存 `peerReadSeq`，并按接口注释加撤回的合并规则（本地已撤回的不被旧版本覆盖、撤回时清 `localPath`、撤回的是最后一条时换预览）
- **PHP**：新增 `recallMessage`；回调事件加 `message_recalled`（透传，`Callback` 不用改）
- 接入文档新增 §4.10、§5.12–§5.15、§8.7；OpenAPI、Skill、`llms-full.txt` 同步

## v0.7.0 — 2026-11-24

没有客服在线时留联系方式。需要 IM 服务端 v1.13.0；旧服务端上除 `leaveCs` 抛 `ImApiException` 外，其余功能不受影响。

- **Flutter**：`ImCsState` 加 `agentsOnline`（旧服务端不给，按 true）、`leaveEnabled`（按 false）与 `canLeave`；新增 `leaveCs({name, phone, email})`，返回留言单号。只加不改
- **PHP**：代码不变；README 的回调示例加 `resolve_user`，after_send 的来源说明加 `wechat`
- 接入文档新增 §8.6 `resolve_user`（微信用户是哪个会员，服务端 v1.16.0）、§10.8 工单进展、§10.9 留言、§10.10 微信渠道，§8.5 用户来源加 `wechat`；OpenAPI 加 `POST /api/imcs/v1/leave`，客服状态加 `agents_online`、`leave_enabled`；README 注明各能力需要的服务端版本；Skill、`llms-full.txt` 同步

## v0.6.0 — 2026-11-24

智能客服：机器人接待状态、转人工、客服消息的发送者角色、回调里的用户来源。需要 IM 服务端 v1.12.0；旧服务端上除 `handoffCs` 抛 `ImApiException` 外，其余功能不受影响。

- **Flutter**：`ImMessage` 加 `senderRole`（`agent` / `bot` / `system`，只有 `@cs` 的消息有）与 `isBot`——机器人的内容由 AI 生成，**界面上要标识**；`ImCsStatus` 加 `bot`；新增 `handoffCs()` 转人工。本地库 v2 → v3 自动升级，升级前已缓存的客服消息 `senderRole` 为 null
- **注意**：用 `switch` 穷尽 `ImCsStatus` 的要补 `bot` 分支；自己实现 `ImStore` 且按列存消息的，要多存 `senderRole`（用 `toJson` / `fromJson` 的不用改）
- **PHP**：代码不变；README 的 after_send 示例改为只给自己的用户推离线（`to_source` 为 `app`，跳过网页访客与平台客服）
- 接入文档新增 §8.5 用户来源、§10.7 网页客服挂件；§10.2–§10.4 补 `sender_role`、机器人与转人工；OpenAPI 加 `POST /api/imcs/v1/handoff`、`POST /api/imcs/v1/visitor`；Skill、`llms-full.txt` 同步

## v0.5.0 — 2026-11-24

会话置顶、免打扰、清空记录、删除会话（都只影响本人，多端同步）。需要 IM 服务端支持会话设置接口（v1.11.0），旧服务端上新方法抛 `ImApiException`，其余功能不受影响。

- **Flutter**：新增 `setPinned` / `setMuted` / `clearConversation` / `deleteConversation`；`ImConversation` 加 `pinnedAt` / `pinned` / `muted` / `clearSeq`；会话快照置顶在前；总未读不计免打扰会话；处理 `conversation_changed` 推送，对账时调 `GET /conversations/changes` 补齐离线期间别的设备的改动；清空 / 删除后旧消息不再补拉、不复现。本地库 v1 → v2 自动升级
- **不兼容**：自己实现 `ImStore`（桌面端注入）的要补 `clearMessages`、`deleteConversation`、`changesCursor`、`setChangesCursor`，并按接口注释更新会话合并、排序、总未读规则
- **PHP**：新增 `conversationSettings` / `setConversationSettings` / `clearConversation` / `deleteConversation`（按对方定位，客服会话对方写 `@cs`）；README 演示 after_send 的 `to_muted`（为 true 时不推离线）
- 接入文档新增 §4.9 服务端会话设置、§5.10 / §5.11 客户端接口；after_send 加 `to_muted`，`to_unread_total` 与 `/unread` 不计免打扰会话；Skill、`llms-full.txt` 同步

## v0.4.1 — 2026-11-23

首个接入方实读 v0.1.0 源码时提的 4 处，PHP SDK 代码不变。

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
