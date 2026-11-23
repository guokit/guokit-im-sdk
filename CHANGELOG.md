# CHANGELOG

两个 SDK（Flutter `guokit_im`、PHP `guokit/im`）共用仓库版本号。

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
