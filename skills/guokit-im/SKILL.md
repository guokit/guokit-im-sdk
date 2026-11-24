---
name: guokit-im
description: 接入 guokit IM（果壳软件即时通讯）时使用：写接入方后端的用户导入、签令牌、封禁、黑名单同步、代发消息、回调验签代码，或写 App / Web 客户端的长连接、断线对账、消息去重、发送重试、图片收发、未读与已读代码。用户提到 guokit IM、guokit-im-sdk、/api/im/v1、X-Api-Key 为 imk_ 开头、Centrifuge 收 IM 推送、IM 回调 X-Im-Signature 时触发。
---

# guokit IM 接入

guokit IM 是可私有部署的即时通讯服务。三方角色：

- **接入方后端**：持有 API Key，调 `/api/im/v1/server/*`（请求头 `X-Api-Key`），负责导入用户、给登录用户签**用户令牌**、接收回调。
- **客户端（App / Web）**：用用户令牌调 `/api/im/v1/*`（`Authorization: Bearer`）发消息、拉会话；用同一令牌连 WebSocket **只收推送**。
- **IM 服务端**：MySQL 为唯一真相，推送只是加速。

权威资料：接口文档 `docs/IM接入文档.md`，机器可读规范 `spec/openapi.yaml`。本 skill 只讲流程与最容易写错的地方；字段细节以这两份为准，不要凭记忆编字段。

## 先看有没有 SDK

- **Flutter 客户端**：用 `guokit_im`（本仓库 `flutter/`），令牌续期、断线对账、本地缓存、发送重试与去重、图片链接重拉都已包好，下面客户端那半不用自己写。
- **PHP 后端**：用 `guokit/im`（本仓库根 `composer.json`，代码在 `php/`），含回调验签。
- 其他语言暂无 SDK，照本 skill 与 references 直接调接口。

## 接入清单

后端：
1. IM 后台新建接入应用拿 API Key，放服务端配置（环境变量 / 密钥管理），**绝不下发客户端**。
2. 存量用户 `POST /server/users/batch` 批量导入（每批 ≤100）；注册、改昵称头像时 `PUT /server/users/{user_id}`。user_id 用自家用户主键字符串，满足 `[A-Za-z0-9_-]{1,64}`。
3. 用户登录时 `POST /server/users/{user_id}/token`，把 `token` 与 `expires_at` 交给客户端；客户端令牌失效时找后端换。
4. 自家封号 → `PATCH /server/users/{user_id}` `{"status":0}`；退出全部设备 → `POST .../kick`；自家拉黑 → `PUT /server/users/{user_id}/blocks/{target}`。
5. 需要审核或离线推送时配回调：before_send 同步审核（2 秒内回），after_send 异步拿到后，`to_source` 为 `app`、`to_online` 为 false 且 `to_muted` 不为 true 时才走厂商推送。站点接了微信渠道、要让坐席认出微信用户是哪个会员的，再实现 `resolve_user`（同步，3 秒内回）。

客户端：
1. 拿到令牌后连 `wss://<IM 域名>/api/im/v1/connect/websocket`（Centrifuge 协议，用官方 SDK：Flutter `centrifuge`、Web `centrifuge`）。
2. 每次 connected（首连与重连）都做一次对账：拉会话列表，落后的会话按 `after_seq` 补拉。
3. 推送从服务端订阅的 publication 事件收：`message` / `read` / `read_all`。
4. 发消息、标已读、上传全走 HTTP。

详细写法：后端看 [references/server.md](references/server.md)，客户端看 [references/client.md](references/client.md)。

## 易错点（每条都是线上真出过或极易出的问题）

1. **不要把 API Key 放进客户端**，因为它能以任何用户身份代发消息、封禁用户；客户端只拿用户令牌。
2. **不要用 `code == "0"` 或真值判断成功**，因为成功时 `code` 是数字 `0`、失败时是字符串（如 `"IM_USER_NOT_FOUND"`）；PHP 用 `=== 0`，JS 用 `=== 0`，Dart 用 `== 0`。
3. **不要把服务端暂时故障当令牌失效**：HTTP 401 `IM_TOKEN_INVALID` 或长连接断开码 3500 才换令牌；HTTP 500 `INTERNAL`、长连接 temporary 错误（code 100）只需重试，SDK 会自动重连。误判会把用户无故登出。
4. **3503 是被封禁或踢下线**，当作登出处理，不要自动换令牌重连，否则踢下线形同虚设。
5. **不要只靠推送收消息**：推送会因断网丢失。每次 connected 都按会话 `max_seq` 对账补拉；收到 `message` 推送时 `seq > 本地最大 seq + 1` 说明跳号，补拉中间段。
6. **发送超时重试必须沿用同一个 `client_msg_id`**，因为服务端按「发送者 + client_msg_id」幂等；换新 id 会发出重复消息。id 在用户点发送时生成（UUID），随本地「发送中」消息一起保存。
7. **自己发的消息要去重**：发送接口返回消息对象，同时长连接也会把这条推回发送者所有设备（含本机）。按消息 `id`（本地未确认时按 `client_msg_id`）合并。
8. **上传图发送要带 `attachment_id` + `ticket` + 宽高**，`ticket` 来自 `/upload` 且与上传者绑定；只带 `url` 会被当成外链图（要求 https）。
9. **收到的上传图 `url` 约 24 小时过期**：不要长期保存链接，本地按 `attachment_id` 缓存图片文件；链接失效时重新拉该消息拿新链接。
10. **回调必须用原始请求体验签**：`hex(HMAC-SHA256(回调密钥, 时间戳 + "\n" + 原始请求体))`，常量时间比较，并校验 `X-Im-Timestamp` 在 5 分钟内；不要先解析 JSON 再序列化后验签。
11. **after_send 会重试**，按 `X-Im-Delivery-Id` 落库去重，见过的直接回 `{"code":0}`；处理慢的逻辑丢队列，先回 200。
12. **before_send 必须显式回 `{"code":0,"data":{"allow":true}}`**，缺省 `allow` 按拒绝处理；超时 2 秒。
13. **不要在客户端 `newSubscription` / 订阅频道**：服务端已自动订阅专属频道，客户端订阅会被拒绝。
14. **收到 `read_all` 要把所有会话未读清零**（或重拉会话列表），它不会附带各会话的 `read_seq`。
15. **`IM_BLOCKED` 是业务结果不是故障**：对方拉黑了发送者，提示「消息已发出，但被对方拒收了」，不要重试。
16. **平台客服是固定联系人 `@cs`**：只能由用户本人从客户端发给它；服务端代发的 from / to 不能是 `@cs`，也不能拉黑 `@cs`。它的消息带 `sender_role`，`bot` 的要向用户标识为 AI 生成。

## 选型提示

- 时间字段是 `YYYY-MM-DD HH:mm:ss`（Asia/Shanghai），不是 ISO 8601。
- id、seq 都是整数；只有 user_id 是字符串。
- 会话列表用游标分页（`cursor`），黑名单列表用 `offset/limit`，不要混用。
- 未读 = `max_seq − read_seq`；自己发的消息会推进自己的 `read_seq`，不计入自己的未读。
