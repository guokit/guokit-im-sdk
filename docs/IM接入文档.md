# IM 接入文档

本文面向接入方的**后端**与**客户端（App / Web）**开发。能力：单聊；文本 / 图片 / 语音 / 文件 / 视频 / 位置 / 自定义七种消息；撤回；对方已读；正在输入；会话列表；未读与标已读；会话置顶、免打扰、清空记录与删除会话；多端同步；发送前 / 发送后 / 撤回回调。
群聊暂不提供。撤回、对方已读、文件与视频消息要站点在「IM 设置」打开才可用（默认关闭）。

下文 `https://im.example.com` 代表你的 IM 服务域名，换成实际地址。

## 1. 概览

```
 ┌──────────────┐   REST（X-Api-Key）：导入用户 / 签令牌 / 封禁 / 代发 / 查历史   ┌──────────────┐
 │  接入方后端   │ ───────────────────────────────────────────────────────────▶ │              │
 │              │ ◀─────────────────────────────────────────────────────────── │   IM 服务端   │
 └──────┬───────┘   回调（签名）：before_send（同步） / after_send 等（异步）│  （MySQL 为准）│
        │ 登录时把用户令牌下发给 App                                            │              │
 ┌──────▼───────┐   HTTP 上行（Bearer 令牌）：发消息 / 会话与设置 / 已读 / 上传  │              │
 │ 客户端 App/Web│ ───────────────────────────────────────────────────────────▶ │              │
 │              │ ◀─────────────────────────────────────────────────────────── │              │
 │              │   WebSocket 下行（Centrifuge 协议）：message / read /          │              │
 └──────────────┘   read_all / conversation_changed 事件                         └──────────────┘
```

客户端**上行全走 HTTP**，WebSocket 只用来**收**推送。

| 名词 | 含义 |
|---|---|
| 接入应用 | 一个调用 IM 服务端接口的后端。在 IM 后台创建，一个 IM 站点可有多个接入应用，**共享同一套用户** |
| API Key | 接入应用的凭证，形如 `imk_xxxxxxxx…`，**只在创建或重置时显示一次**，丢了只能重置（旧 Key 立即失效） |
| user_id | 用户在 IM 里的唯一标识，由接入方决定，限 `[A-Za-z0-9_-]{1,64}`。同一 user_id 在所有接入应用里是同一个人 |
| 用户令牌 | IM 服务端为某个 user_id 签发的凭证，客户端调接口与连长连接都用它。接入方后端调接口拿，**不在本地计算** |
| 会话 | 两个用户之间的单聊，`conversation_id` 为整数，首次发消息时自动创建 |
| seq | 消息在会话内的序号，从 1 开始、连续递增、不跳号。补拉、已读、未读都以它为准 |

## 2. 接入步骤

1. **建应用拿 Key**：IM 后台 →「IM」→「接入应用」→ 新建，复制 API Key 存到后端配置（不要下发到客户端）。
2. **导入用户**：存量用户用 `POST /server/users/batch` 批量导入；新注册 / 改昵称头像时调 `PUT /server/users/{user_id}`。
3. **登录时签令牌**：用户登录你的产品后，后端调 `POST /server/users/{user_id}/token`，把 `token` 与 `expires_at` 下发给 App。
4. **App 连长连接并拉会话**：App 用令牌连 WebSocket（§6），连上后拉会话列表（§7）。
5. **配回调（可选）**：IM 后台 →「IM 设置」填回调地址、回调密钥，按需开启发送前回调；Web 端还要在这里加 Origin 白名单。

## 3. 通用约定

- 统一前缀 `/api/im/v1`，请求与响应均为 JSON（上传除外），UTF-8。响应包 `{"code": 0, "message": "ok", "data": {}}`：
  **成功时 `code` 是数字 `0`；失败时 `code` 是字符串**（如 `"IM_USER_NOT_FOUND"`），`data` 为 `{}`，`message` 为中文说明。
  判断成功请用严格比较：PHP `$r['code'] === 0`、Dart `r['code'] == 0`，不要用 `"0"`。
- 时间：字符串 `YYYY-MM-DD HH:mm:ss`，时区固定 Asia/Shanghai（UTC+8），如 `"2026-11-20 10:00:00"`。
- 各种 id、seq 均为整数（user_id 除外，它是字符串）。

**HTTP 状态与业务码**

| HTTP | code | 含义 |
|---|---|---|
| 200 | `0` | 成功 |
| 400 | `VALIDATION` | 参数不合法，`message` 说明原因 |
| 401 | `IM_KEY_INVALID` | `X-Api-Key` 缺失、错误，或接入应用已停用 |
| 401 | `IM_TOKEN_INVALID` | 用户令牌缺失、验签失败、已过期，或用户已被封禁 / 踢下线 → 找后端换新令牌 |
| 200 | `IM_USER_NOT_FOUND` | 用户不存在（签令牌、封禁、踢下线、发消息的收发方） |
| 200 | `IM_USER_DISABLED` | 用户已封禁（签令牌、发消息的收发方） |
| 200 | `IM_MESSAGE_REJECTED` | 消息被发送前回调拒绝，`message` 形如 `消息被拒绝：<原因>` |
| 200 | `IM_BLOCKED` | 收件人已把发送者拉黑（发消息、代发），`message` 为「对方已将你拉黑」 |
| 200 | `IM_RECALL_NOT_ALLOWED` | 不能撤回：站点没开启撤回，或超过时限（§5.12），`message` 说明原因 |
| 200 | `IM_RATE_LIMITED` | 超频：接入应用调用超限，或该用户发消息超限（§9） |
| 403 | `FORBIDDEN` | 客户端访问了自己不在其中（或不存在）的会话 |
| 404 | `VALIDATION` | 会话不存在：服务端审计查询（§4.6）或会话设置（§4.9）查不到会话；置顶一个不在列表里（已删除）的会话（§5.10）。消息不存在：撤回时（§4.10、§5.12），不是本人发的也按不存在 |
| 403 | `LICENSE_INVALID` / `LICENSE_EXPIRED` / `LICENSE_DOMAIN` | IM 站点授权异常，联系 IM 服务提供方 |
| 500 | `INTERNAL` | 服务端错误，可稍后重试 |

**消息对象**（发消息的返回值、拉消息列表、推送、回调里都是这个形状）：

```json
{
  "id": 1024, "conversation_id": 12, "seq": 37, "from": "u1001",
  "type": "text", "content": { "text": "你好" },
  "client_msg_id": "6f1c7f3e-0b8a-4a59-9d1e-2b1e5f0c9a11",
  "created_at": "2026-11-20 10:00:00"
}
```

客服（`@cs` 与 `@cs:<主体标识>`，§10.11）的消息另带 `sender_role`，见 §10.2。

**撤回后的消息** `type` 变成 `recalled`，`content` 为 `{"by": "sender" | "agent" | "server"}`（发送者 / 坐席 / 接入方），其余字段不变，原文不再给出，见 §5.12。**`type` 将来可能增加取值，不认识的按「暂不支持的消息」兜底显示，不要报错。**

## 4. 服务端接口（接入方后端调用）

鉴权：请求头 `X-Api-Key: <API Key>`。路径前缀 `/api/im/v1/server`。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/ping` | 连通与 Key 自检，返回 `{app_id, name}` |
| PUT | `/users/{user_id}` | 导入或更新单个用户 |
| POST | `/users/batch` | 批量导入 |
| POST | `/users/{user_id}/token` | 签用户令牌 |
| PATCH | `/users/{user_id}` | 封禁 / 解封 |
| POST | `/users/{user_id}/kick` | 踢下线 |
| POST | `/messages` | 以某用户身份发消息 |
| POST | `/messages/{id}/recall` | 撤回消息 |
| GET | `/conversations/{id}/messages` | 查会话历史（审计） |
| PUT | `/users/{user_id}/blocks/{target}` | 拉黑 |
| DELETE | `/users/{user_id}/blocks/{target}` | 解除拉黑 |
| GET | `/users/{user_id}/blocks` | 黑名单列表 |
| POST | `/users/online` | 批量查询在线状态 |
| GET | `/users/{user_id}/conversations/{peer_id}` | 查询某用户对某会话的设置 |
| PUT | `/users/{user_id}/conversations/{peer_id}/settings` | 替用户置顶 / 免打扰 |
| POST | `/users/{user_id}/conversations/{peer_id}/clear` | 替用户清空聊天记录 |
| DELETE | `/users/{user_id}/conversations/{peer_id}` | 替用户删除会话 |

### 4.1 导入或更新用户 `PUT /users/{user_id}`

请求 `{"nickname": "张三", "avatar_url": "https://…"}`：`nickname` 可空、≤64 字；`avatar_url` 可空、http(s) 且 ≤512 字符。返回 `{"user_id": "u1001"}`。用户已存在时**只覆盖昵称与头像**（传空串即清空），不改封禁状态、不影响已签令牌。
user_id 不合法 → 400 `VALIDATION`。

### 4.2 批量导入 `POST /users/batch`

```json
{ "users": [ { "user_id": "u1001", "nickname": "张三", "avatar_url": "https://cdn.example.com/a.png" } ] }
```

每批 1–100 个，任一项不合法则**整批拒绝**（`message` 指出第几个），同一事务写入。返回 `{"count": 1}`。
已存在的用户与 §4.1 相同：**只覆盖昵称与头像**（传空串即清空），不改封禁状态、不影响已签令牌，所以存量导入可以放心重复执行。

### 4.3 签令牌 `POST /users/{user_id}/token`

无请求体。返回：

```json
{ "code": 0, "message": "ok", "data": { "token": "eyJ0eXAiOi…", "expires_at": "2026-11-27 10:00:00" } }
```

- 有效期默认 168 小时（7 天），IM 后台「IM 设置」可调（1–8760 小时）。
- 每次调用签一个新令牌，**之前签的令牌照样有效**直到过期；要让旧令牌全部作废请用踢下线。
- 令牌是不透明字符串，客户端不要解析它，以 `expires_at` 判断何时续签。
- 用户不存在 → `IM_USER_NOT_FOUND`（先导入再签）；已封禁 → `IM_USER_DISABLED`。

curl：

```bash
curl -X POST https://im.example.com/api/im/v1/server/users/u1001/token \
  -H "X-Api-Key: imk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

PHP（Guzzle）：登录时先同步资料、再签令牌：

```php
use GuzzleHttp\Client;

function imCall(string $method, string $path, ?array $json = null): array {
    static $http;
    $http ??= new Client(['base_uri' => 'https://im.example.com', 'timeout' => 5, 'http_errors' => false]);
    $opt = ['headers' => ['X-Api-Key' => getenv('IM_API_KEY')]];
    if ($json !== null) $opt['json'] = $json;
    $res = $http->request($method, '/api/im/v1/server' . $path, $opt);
    return json_decode((string) $res->getBody(), true) ?: ['code' => 'INTERNAL', 'message' => 'bad response'];
}

$uid = (string) $user->id;                       // 你的用户主键，须满足 [A-Za-z0-9_-]{1,64}
imCall('PUT', '/users/' . rawurlencode($uid), ['nickname' => $user->nickname, 'avatar_url' => $user->avatar]);
$r = imCall('POST', '/users/' . rawurlencode($uid) . '/token');
if ($r['code'] === 0) {
    return ['im_token' => $r['data']['token'], 'im_expires_at' => $r['data']['expires_at']];
}
throw new RuntimeException("IM 签令牌失败：{$r['code']} {$r['message']}");
```

### 4.4 封禁 / 解封、踢下线

- `PATCH /users/{user_id}`，请求 `{"status": 0}`（`0` 封禁、`1` 正常），返回 `{"user_id", "status"}`。封禁使该用户**全部已签令牌立即失效**并断开所有长连接；解封不恢复旧令牌，需重新签发。
- `POST /users/{user_id}/kick`，无请求体，返回 `{"user_id"}`。效果同封禁的失效与断连，但用户仍正常、可重新签令牌，适合「改密码 / 退出全部设备」。

### 4.5 代发消息 `POST /messages`

请求体同客户端发消息（§5.1），多一个 `from` 字段指定发送者。走与客户端完全相同的流程：校验、限速（按 `from` 计）、幂等、发送前回调、推送、发送后回调。返回消息对象。
收件人已把 `from` 拉黑时同样回 `IM_BLOCKED`（§4.7）。
注意：服务端拿不到用户的上传凭证，**代发图片请用 `url` 形式**（你自己的 https 图片地址），语音、文件、视频不能代发。要发单据、附件，用业务卡片的 `web_link`（§5.9）指到你自己的页面。

### 4.6 查会话历史 `GET /conversations/{id}/messages`

参数与客户端拉消息相同（§5.3），不校验成员身份，也不受用户清空记录或删除会话（§5.10）影响，始终返回全量。会话不存在 → 404 `VALIDATION`。

### 4.7 黑名单

- **A 拉黑 B 后，B 发给 A 的消息回 `IM_BLOCKED`**（HTTP 200 + 业务码）：消息不落库、不推送、不触发 before_send、不产生 after_send 回调。客户端发与服务端代发（§4.5）都拦截。
- **A 发给 B 不受影响**，拉黑只管「拒收对方」。
- 拉黑前已成功发出的消息，弱网重发（同一 `client_msg_id`）仍返回原消息，不会报被拉黑；被拦的尝试也不占发送限速配额。
- 双方 `user_id` 只校验格式（`[A-Za-z0-9_-]{1,64}`），**不要求已导入**。不能拉黑自己，也不能拉黑客服（`@cs`、`@cs:…`），均回 400 `VALIDATION`。
- 拉黑、解除都是幂等的：重复拉黑不报错、不改拉黑时间；解除不存在的记录也返回成功。两者都返回 `{}`。
- 拉黑与解除不推送事件、不触发回调；已存在的会话与历史消息不动，双方照常能看到。

接口（`{user_id}` 是拉黑方，`{target}` 是被拉黑方）：

| 方法 | 路径 | 说明 |
|---|---|---|
| PUT | `/users/{user_id}/blocks/{target}` | 拉黑，返回 `{}` |
| DELETE | `/users/{user_id}/blocks/{target}` | 解除，返回 `{}` |
| GET | `/users/{user_id}/blocks?offset=&limit=` | 列表，按拉黑时间倒序；`offset` 默认 0，`limit` 默认 50、最大 200 |

列表返回（`user_id` 是被拉黑方；不带昵称头像，请用自己的用户资料展示）：

```json
{ "items": [ { "user_id": "u1002", "created_at": "2026-11-21 10:00:00" } ], "has_more": false }
```

`has_more` 为 `true` 时，把 `offset` 加上本页条数继续取下一页。

### 4.8 查询在线状态 `POST /users/online`

```json
{ "user_ids": ["u1001", "u1002", "u9999"] }
```

返回（按请求顺序，重复的 id 只返回一次）：

```json
{ "items": [
  { "user_id": "u1001", "online": true },
  { "user_id": "u1002", "online": false },
  { "user_id": "u9999", "online": false }
] }
```

- 每次 1–100 个，`user_id` 规则同 §4.1；为空、超过 100 个或含不合法的 id → 400 `VALIDATION`。
- **在线 = 该用户此刻至少有一条长连接**，与 after_send 的 `to_online` 同一口径。不存在、被封禁的用户都返回 `false`，不报错。
- 这是在线状态的**权威来源**；上下线回调（§8.4）只是提醒。查到之后怎么展示（App 里的小绿点、是否允许用户隐藏在线状态等）由接入方决定。

### 4.9 会话设置

替某个用户置顶 / 免打扰、清空记录、删除会话。含义、返回值与客户端接口（§5.10）完全相同，改的是同一份数据；成功后同样向**该用户**的所有在线设备推 `conversation_changed`（§6），对方不会收到任何通知。

接入方后端手里通常是好友的 user_id 而不是会话 id，所以这组接口**按对方定位会话**：`{user_id}` 是设置归属的用户，`{peer_id}` 是对方的 user_id，客服会话写 `@cs`（其他客服主体写 `@cs:<主体标识>`，§10.11）。

| 方法 | 路径 | 请求体 | 说明 |
|---|---|---|---|
| GET | `/users/{user_id}/conversations/{peer_id}` | — | 查询会话设置 |
| PUT | `/users/{user_id}/conversations/{peer_id}/settings` | `{"pinned"?: bool, "muted"?: bool}` | 置顶 / 免打扰，至少给一项 |
| POST | `/users/{user_id}/conversations/{peer_id}/clear` | 无 | 清空该用户这一侧的记录 |
| DELETE | `/users/{user_id}/conversations/{peer_id}` | 无 | 删除会话 |

四个接口都返回会话设置对象（字段见 §5.10）：

```json
{ "conversation_id": 12, "peer_user_id": "u1002", "pinned": false, "pinned_at": null,
  "muted": true, "clear_seq": 0, "unread": 3, "visible": true }
```

```bash
curl -X PUT https://im.example.com/api/im/v1/server/users/u1001/conversations/u1002/settings \
  -H "X-Api-Key: imk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" \
  -H "Content-Type: application/json" -d '{"muted": true}'
```

- **没聊过的会话回 404 `VALIDATION`「会话不存在」**：会话在第一条消息发出时才创建，所以不能提前给没聊过的人设置免打扰。
- 用户不必已导入（同黑名单 §4.7），只校验格式；`{user_id}` 不能是 `@cs`，`{peer_id}` 可以是。格式不合法 → 400 `VALIDATION`。
- 会话被该用户删除后仍能查询，此时 `visible` 为 `false`，也可以照常设置免打扰、清空、再次删除；但置顶会回 404 `VALIDATION`「会话不存在」（§5.10）。
- 其他参数错误（两项都不给、置顶超过 50 个）同 §5.10，回 400 `VALIDATION`。

### 4.10 撤回消息 `POST /messages/{id}/recall`

无请求体，返回撤回后的消息对象。**不限时、不看站点的撤回开关**，用于处理违规内容。效果与用户自己撤回相同（§5.12），`content.by` 为 `server`。
渠道用户（网页访客、微信）参与的会话、客服发的消息都按不存在处理，回 404 `VALIDATION`。已撤回的再调返回同一结果，不再推送、不再回调。
撤回后 §4.6 的审计查询也只给撤回后的形态，**原文只在 IM 后台的「消息查询」里看得到**。

## 5. 客户端接口（App / Web 调用）

鉴权：请求头 `Authorization: Bearer <用户令牌>`。路径前缀 `/api/im/v1`。令牌失效统一回 401 `IM_TOKEN_INVALID`，此时向自家后端换新令牌后重试。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/me` | 当前用户 `{user_id, nickname, avatar_url, features}`，可用作令牌自检。`features` 是站点开关：`recall_minutes` 撤回时限（分钟，0 = 没开启）、`read_receipt` 是否显示对方已读、`file_max_mb` / `video_max_mb` **当前用户**能发的文件、视频大小上限（MB，0 = 不能发，不要显示入口） |
| POST | `/messages` | 发消息 |
| GET | `/conversations` | 会话列表（游标分页） |
| GET | `/conversations/{id}/messages` | 补拉 / 翻历史 |
| POST | `/conversations/{id}/read` | 标已读 |
| GET | `/unread` | 总未读 |
| POST | `/upload` | 上传图片 / 语音 / 文件 / 视频 |
| PUT | `/blocks/{target}` | 拉黑 |
| DELETE | `/blocks/{target}` | 解除拉黑 |
| GET | `/blocks` | 黑名单列表 |
| POST | `/conversations/read-all` | 一键清全部未读 |
| PUT | `/conversations/{id}/settings` | 置顶 / 免打扰 |
| POST | `/conversations/{id}/clear` | 清空聊天记录 |
| DELETE | `/conversations/{id}` | 删除会话 |
| GET | `/conversations/changes` | 会话设置增量补齐 |
| POST | `/messages/{id}/recall` | 撤回自己的消息 |
| GET | `/recalls` | 撤回增量补齐 |
| POST | `/conversations/{id}/typing` | 正在输入 |

### 5.1 发消息 `POST /messages`

| 字段 | 类型 | 说明 |
|---|---|---|
| to | string | 接收方 user_id，不能是自己 |
| type | string | `text` / `image` / `voice` / `file` / `video` / `location` / `custom` |
| content | object | 按 type，见下表 |
| client_msg_id | string | 必填，1–64 字符，客户端生成的唯一 id |

返回消息对象（含服务端分配的 `id`、`conversation_id`、`seq`）。接收方不存在 → `IM_USER_NOT_FOUND`，已封禁 → `IM_USER_DISABLED`，接收方已把你拉黑 → `IM_BLOCKED`（§5.7）。

**content 约束**（多余字段会被丢弃，落库的是规整后的内容）：

| type | content | 约束 |
|---|---|---|
| `text` | `{"text"}` | 1–5000 字，不能全是空白 |
| `image`（上传图） | `{"attachment_id", "ticket", "width", "height"}` | `attachment_id`、`ticket` 来自 `/upload`，且必须是**发送者本人**上传的；宽高为 1–20000 的整数 |
| `image`（外链图） | `{"url", "width", "height"}` | `url` 为 https 链接，≤1024 字符，原样存取；宽高同上 |
| `voice` | `{"attachment_id", "ticket", "duration"}` | `attachment_id`、`ticket` 来自 `/upload`（`kind=voice`），且必须是**发送者本人**上传的；`duration` 为 1–60 的整数秒，由客户端上报。只支持上传的语音；网页访客、服务端代发不能发 |
| `file` | `{"attachment_id", "ticket", "name"}` | `attachment_id`、`ticket` 来自 `/upload`（`kind=file`），且必须是**发送者本人**上传的；`name` 是显示与下载用的文件名，扩展名要和内容对得上（§5.6 的对照表）。站点没开启、服务端代发不能发；网页访客要站点另外允许 |
| `video` | `{"attachment_id", "ticket", "duration", "width", "height"}`，可选 `cover_attachment_id`、`cover_ticket` | `attachment_id`、`ticket` 来自 `/upload`（`kind=video`），且必须是**发送者本人**上传的；`duration` 为 1–3600 的整数秒，宽高为 1–20000 的整数，都由客户端上报。封面是一张用 `/upload`（图片）上传的图，没有封面就不带这两个键。站点没开启、网页访客、服务端代发不能发 |
| `location` | `{"lat", "lng", "name", "address"}` | `lat` ∈ [-90, 90]、`lng` ∈ [-180, 180]，必填；`name` ≤100 字、`address` ≤200 字 |
| `custom` | `{"data", "desc"}` | `data` 必须是 JSON **对象**，压缩序列化后 ≤8KB；`desc` 必填，1–100 字，用于会话预览与离线推送文字。订单、商品这类业务卡片可在 `data.im_card` 里带标准卡片外壳，见 §5.9 |

图片两种形式**二选一**，同时传 `attachment_id` 与 `url` 会被拒；上传图的附件必须真是图片，拿别的附件当图片发会被拒。
收到的上传图消息 content 为 `{"attachment_id", "width", "height", "url"}`：`url` 是**每次读取时现签**的临时链接（约 24 小时有效），不要长期保存；本地按 `attachment_id` 缓存图片，链接过期就重新拉一次该消息拿新链接。外链图原样返回 `{"url", "width", "height"}`。
收到的语音消息 content 为 `{"attachment_id", "duration", "size", "mime", "url"}`：`size`（字节）与 `mime`（`audio/mp4` / `audio/mpeg`；微信用户发来的语音是 `audio/wave`，8kHz 单声道，见 §10.10）由服务端给，`url` 规则同上传图。旧版客户端不认识 `voice`，请先让用户升级再开放发语音。
收到的文件消息 content 为 `{"attachment_id", "name", "size", "mime", "url"}`：`size`（字节）与 `mime` 由服务端给；`url` 是强制下载、下载下来就是 `name` 的地址，有效期规则同上传图，网页里用 `target="_blank"` 打开即可。`name` 会去掉路径、控制字符与看不见的格式字符，超过 100 字的截短（保住扩展名）。
收到的视频消息 content 为 `{"attachment_id", "duration", "width", "height", "size", "mime", "cover_attachment_id", "url", "cover_url"}`：`mime` 为 `video/mp4` 或 `video/quicktime`；没有封面时 `cover_attachment_id` 为 `0`、`cover_url` 为空串。两个链接的有效期规则同上传图。**收到的视频不一定放得了**：服务端不转码，iPhone 默认拍的是 HEVC，很多浏览器放不了，播放失败时请给用户下载链接。
旧版客户端不认识 `file` 与 `video`（会显示兜底文字，会话预览可能是空白），请等用户都升级后再让站点打开。

会话预览文字：text 取前 50 字，image 为 `[图片]`，voice 为 `[语音]`，file 为 `[文件] 文件名`（合计截到 50 字），video 为 `[视频]`，location 为 `[位置]`，custom 取 `desc`，已撤回的为 `[消息已撤回]`。

**client_msg_id 幂等**：同一发送者的 `client_msg_id` 全局唯一（跨会话）。重复提交会直接返回**第一次的那条消息**（code 0，不再推送、不再回调），即使内容不同也以第一次为准；那条已被撤回时返回撤回后的形态。
做法：用户点发送时生成 UUID，随本地「发送中」消息一起保存；超时或断网重试时**沿用同一个**，就不会重复发。

### 5.2 会话列表 `GET /conversations?cursor=&limit=`

- 只列出本人列表里的会话：有过消息，且没被本人删除（§5.10）。
- **置顶优先**：不带 `cursor` 的首页先放**全部**置顶会话（按置顶时间倒序，最多 50 个），再接 `limit` 条非置顶会话，所以首页条数可能大于 `limit`；非置顶会话按最后一条消息时间倒序。
- `limit` 默认 20，最大 50（超出按 50），**只约束非置顶会话**；`cursor` 首页不传，之后传上一页返回的 `next_cursor`，**后续页只翻非置顶会话**，不会再出现置顶的；`next_cursor` 为空串表示没有下一页。

```json
{ "items": [ {
    "conversation_id": 12, "type": "c2c",
    "peer": { "user_id": "u1002", "nickname": "李四", "avatar_url": "https://cdn.example.com/b.png" },
    "last_message": { "seq": 37, "from": "u1002", "type": "text", "preview": "晚上见", "created_at": "2026-11-20 10:00:00" },
    "unread": 3, "max_seq": 37, "read_seq": 34, "last_msg_at": "2026-11-20 10:00:00",
    "pinned": true, "pinned_at": "2026-11-19 09:30:00", "muted": false, "clear_seq": 0
  } ],
  "next_cursor": "MTc2MzYwNDAwMDoxMg" }
```

| 字段 | 说明 |
|---|---|
| pinned / pinned_at | 本人是否置顶、置顶时间；未置顶为 `false` / `null` |
| muted | 本人是否免打扰。免打扰会话的 `unread` 照常计数，但不计入总未读（§5.5） |
| clear_seq | 本人清空到的序号，拉消息只会返回比它大的 seq（§5.3）；没清空过为 `0` |
| peer_read_seq | 对方读到哪条（§5.14）。**站点没开启对方已读、以及客服会话没有这个字段** |

`last_message` 请判空：本人清空记录后还没有新消息时为 `null`（会话仍在原位置，`unread` 为 0），极少数其他情况下也可能为 `null`。
会话被本人删除后不在列表里，有新消息时会自动重新出现（不再置顶，免打扰保留）。

### 5.3 拉消息 `GET /conversations/{id}/messages`

| 参数 | 说明 |
|---|---|
| after_seq | 补拉：返回 `seq > after_seq` 的消息 |
| before_seq | 翻历史：返回 `seq < before_seq` 的消息 |
| （都不传） | 最新一页 |
| limit | 默认 30，最大 100（超出按 100） |

`after_seq` 与 `before_seq` 只能传一个。返回 `{"items": [消息对象…], "has_more": true}`，**items 一律按 seq 升序**。
`has_more` 表示查询方向上还有更多：补拉时表示后面还有新消息，继续用最后一条的 seq 补拉；翻历史 / 最新一页时表示更早还有，用第一条的 seq 作 `before_seq` 继续翻。
不是会话成员（或会话不存在）→ 403 `FORBIDDEN`。

**清空记录或删除会话（§5.10）之后只返回 `seq > clear_seq` 的消息**，即从 `clear_seq + 1` 开始：`after_seq` 小于 `clear_seq` 时等同于传 `clear_seq`；翻历史翻到 `clear_seq + 1` 就到头，`has_more` 为 `false`；清空后还没有新消息时 `items` 为空。`clear_seq` 在会话列表（§5.2）与会话设置（§5.10）里都有。只影响本人，对方照常拉到全部消息。

### 5.4 标已读 `POST /conversations/{id}/read`

请求 `{"seq": 37}`（通常传当前看到的最大 seq），返回 `{"read_seq": 37, "unread": 0}`。
已读位置**只进不退**，超过会话最大 seq 时按最大 seq 处理。成功后会向自己所有在线设备推 `read` 事件。

### 5.5 总未读 `GET /unread`

返回 `{"total": 5}`，即该用户所有**非免打扰**会话的未读之和，可直接用于 App 角标。
免打扰会话自己的 `unread` 照常计数，只是不计入这里（客户端可以给它显示小红点而不是数字）。与 after_send 的 `to_unread_total`（§8.2）同一口径。

### 5.6 上传图片 / 语音 / 文件 / 视频 `POST /upload`

`multipart/form-data`，文件字段名 `file`；可选字段 `kind`：`image`（缺省）、`voice`、`file` 或 `video`。

- **图片**：只收 JPEG / PNG / GIF / WebP（按文件内容识别，不看扩展名），大小上限取站点「图片上限」设置（默认 8MB）。
- **语音**：只收 m4a（AAC）与 mp3（按文件内容识别），不超过 2MB 与站点「图片上限」中较小的一个。推荐 AAC-LC 单声道的 m4a，iOS、Android、浏览器都能直接播放；小程序录音用 mp3。AMR、Opus、裸 AAC 不收。
- **文件**：站点在「IM 设置」开启后可用（默认关闭），大小上限见 `/me` 的 `features.file_max_mb`（站点可配 1–100MB）。按文件内容识别类型，**文件名（multipart 的 `filename`）的扩展名还要和内容对得上**，见下表；表里没有的一律不收。图片、语音、视频请按各自的类型发。
- **视频**：站点开启后可用（默认关闭），大小上限见 `features.video_max_mb`。只收 mp4 与 mov（按文件内容识别，不看扩展名）。服务端不转码、不截封面，**发送前请转成 H.264 的 MP4**，否则对方可能放不了。

| 内容 | 收到的 `mime` | 允许的扩展名 |
|---|---|---|
| PDF | `application/pdf` | pdf |
| Word | `application/vnd.openxmlformats-officedocument.wordprocessingml.document` | docx |
| Excel | `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` | xlsx |
| PowerPoint | `application/vnd.openxmlformats-officedocument.presentationml.presentation` | pptx |
| 老式 Office / WPS | `application/x-ole-storage` | doc、xls、ppt、wps、et、dps |
| 纯文本 | `text/plain` | txt、csv、md、log |
| 压缩包 | `application/zip` | zip |
| 压缩包 | `application/x-rar-compressed` | rar |

改扩展名骗不过去：apk、jar 的内容是 zip，msi 是老式 Office 的格式，bat 是纯文本，扩展名对不上都会被拒。已知的误判：开头像 HTML 标签的 txt、md 会被拒；里面有 `word/` 目录的普通 zip 会被认成 docx，按 `.zip` 发会被拒。服务端**不做病毒扫描**，请提醒用户当心来源不明的文件。

```json
{ "attachment_id": 5531, "url": "https://im.example.com/files/…", "ticket": "q8Zr…" }
```

`url` 是临时链接，仅供本地预览；发图片消息时带 `attachment_id` + `ticket` + 宽高，发语音消息时带 `attachment_id` + `ticket` + 时长，发文件消息时带 `attachment_id` + `ticket` + 文件名，发视频消息时带 `attachment_id` + `ticket` + 时长 + 宽高（有封面再带封面的 `attachment_id` 与 `ticket`）。`ticket` 与上传者绑定，别人拿去发不出去。`kind=file` 返回的 `url` 就是强制下载的地址。

- 没开启、超过上限、类型不符 → 400 `VALIDATION`，`message` 可直接显示；上传过于频繁、当天的文件与视频数到上限 → `IM_RATE_LIMITED`（§9）。
- **发之前先在本地按 `features` 判断大小**：请求体超过服务端上限时，服务端不收完就回错误并断开，弱网下客户端可能只看到网络错误。
- 站点前面的反向代理要把请求体上限配到比文件、视频上限大 1MB 以上，否则代理直接回 413（不是 JSON 响应包）。
- 上传慢，超时要放宽（SDK 为 5 分钟）。附件传好后 `attachment_id` 与 `ticket` 可以反复用，发消息失败重试时不要再传一次。

### 5.7 黑名单

语义与 §4.7 相同（对方被你拉黑后发给你的消息回 `IM_BLOCKED`、你发给对方不受影响、幂等、不推送事件），拉黑方是**令牌里的用户**，不需要也不能指定别人。
客户端 `/blocks` 与服务端 `/users/{user_id}/blocks`（§4.7）读写的是**同一份名单**，任一端改了另一端立即可见；接入方用其中一种维护即可，不必两边同步。

| 方法 | 路径 | 说明 |
|---|---|---|
| PUT | `/blocks/{target}` | 拉黑，返回 `{}` |
| DELETE | `/blocks/{target}` | 解除，返回 `{}` |
| GET | `/blocks?offset=&limit=` | 列表，按拉黑时间倒序；`limit` 默认 50、最大 200 |

列表返回 `{"items": [{"user_id", "created_at"}], "has_more"}`，同 §4.7。`target` 不合法、是自己或是客服 → 400 `VALIDATION`。

### 5.8 一键清全部未读 `POST /conversations/read-all`

无请求体。把该用户所有会话（含客服会话、免打扰会话，以及已删除不在列表里的会话）的已读位置推到各自最新一条，返回 `{"updated": 3}`，`updated` 是本次实际变更的会话数（没有未读时为 `0`）。
`updated > 0` 时会向自己所有在线设备（含发起这次请求的设备）推**一条** `read_all` 事件（§6），不会逐会话推 `read`。

### 5.9 业务卡片 `im_card`

订单、商品、服务、文章这类「点开是一个详情页」的消息，都用 `custom` 发。IM 不认识你的业务数据，
所以约定一个**通用卡片外壳**：放在 `custom.data.im_card` 里，各端照这份规范渲染。站点的客服工作台、
后台消息查询都按它画卡片；不带 `im_card` 的 custom 消息仍只显示 `desc`。

`data` 里的其他字段照旧归你自己用（例如你自己的卡片协议），`im_card` 是 `data` 里的**保留键名**；
`desc` 照旧必填，用于会话预览、离线推送，以及不认识卡片的客户端的兜底显示。

```json
{
  "to": "u1002",
  "type": "custom",
  "client_msg_id": "c-20261123-001",
  "content": {
    "desc": "[订单] 有机大米 5kg × 2",
    "data": {
      "im_card": {
        "kind": "order",
        "title": "有机大米 5kg × 2",
        "subtitle": "云仓自营",
        "image": "https://cdn.example.com/p/123.jpg",
        "fields": [
          { "label": "订单号", "value": "SO20261123001" },
          { "label": "状态", "value": "待发货" },
          { "label": "实付", "value": "¥128.00" }
        ],
        "web_link": "https://shop.example.com/orders/1",
        "app_link": "example://order/1",
        "mp_path": "/pages/order/detail?id=1"
      }
    }
  }
}
```

| 字段 | 必填 | 规则 | 用途 |
|---|---|---|---|
| `title` | 是 | 去首尾空白后 1–64 字 | 卡片标题 |
| `kind` | 否 | ≤20 字符 | 推荐 `order` / `product` / `service` / `article` / `page`，只用于显示类型名与图标；其他值显示为「链接」。`ticket` 由站点的工单进展使用（§10.8） |
| `subtitle` | 否 | ≤100 字 | 副标题 |
| `image` | 否 | https，≤1024 字符 | 封面 / 缩略图 |
| `fields` | 否 | 数组，最多 6 行；每行 `{"label", "value"}`，label 1–10 字、value 1–64 字 | 关键信息，**发送那一刻的快照** |
| `web_link` | 否 | https，≤1024 字符 | 浏览器打开：网站、H5、站点客服工作台 |
| `app_link` | 否 | ≤1024 字符，不含空白，scheme 不限 | 原生 App 内跳转 |
| `mp_path` | 否 | 以 `/` 开头，≤512 字符，不含空白 | 小程序页面路径 |
| `mp_appid` | 否 | ≤32 个字母或数字；带了 `mp_path` 才能填 | 不填跳本小程序；填了跳到另一个小程序 |

- `data` 里出现 `im_card` 键就必须是 JSON 对象（`null` 也不行）；卡片里的可选字段写成 `null` 视为没带，可选的字符串字段写成空串也视为没带；上表以外的键原样保存，渲染方忽略（为以后加字段留余地）。
- 不合规范**整条消息拒收**：400 `VALIDATION`，`message` 写明字段，例如 `custom.data.im_card.title 须为 1–64 字`。客户端发送（§5.1）与服务端代发（§4.5）同样校验。
- 服务端只校验格式与长度，**不判断链接能不能打开**。

**各端用哪个链接**：一张卡片可以三种都带，各端取自己能用的。

| 端 | 用 | 说明 |
|---|---|---|
| 网站 / H5 / 站点客服工作台 | `web_link` | 浏览器新窗口打开 |
| 原生 App | `app_link` | 自定义 scheme 或通用链接 |
| 微信小程序 | `mp_path`（+ `mp_appid`） | 本小程序内 `navigateTo`；带 `mp_appid` 时跳另一个小程序。小程序要打开 `web_link` 得用 web-view，且该域名须先在小程序后台配成「业务域名」（仅企业主体可配），否则打不开 |

**链接打不开时**：

- **关键信息放进 `fields`**。坐席和用户即使打不开链接，也知道说的是哪一单；工作台上注明「发送时信息」，点一下值即可复制（例如复制订单号去你的后台查）。最新状态以点开详情为准。
- **客服工作台只用 `web_link`**。没有 `web_link` 时显示「请在用户端查看」。`web_link` 若指向需要登录的后台页，坐席要在那边有账号和权限；登录、无权限、对象已删除由你的页面自己处理。
- **留意域名**。卡片可能是用户从客户端发出的，工作台会在「打开详情」旁显示链接域名，请坐席只点自家域名的链接。
- 卡片里的手机号、收货地址等个人信息建议在发送端脱敏：卡片快照会永久保存在消息里，坐席、后台查询与回调接收方都能看到。

**示例**：

- 商品：`{"kind": "product", "title": "有机大米 5kg", "image": "https://…", "fields": [{"label": "价格", "value": "¥64.00"}], "web_link": "https://shop.example.com/p/123", "mp_path": "/pages/product/detail?id=123"}`
- 普通页面（文章 / 活动）：`{"kind": "article", "title": "双 11 活动说明", "subtitle": "11 月 1 日–11 日", "web_link": "https://www.example.com/news/88"}`
- 已有自己卡片协议的（如 `{"schema": "my_card", "type": "order", "payload": {…}}`）：协议原样保留，在同一个 `data` 里**加一个** `im_card` 键即可，自家 App 继续按自己的协议渲染，客服工作台按 `im_card` 渲染。

### 5.10 置顶、免打扰、清空与删除

每个用户对自己的每个会话各自设置，**只影响本人这一侧**：对方看不到、也不会收到任何通知；消息本身不删除，对方、服务端审计查询（§4.6）和客服坐席看到的历史都不变。

| 方法 | 路径 | 请求体 | 效果 |
|---|---|---|---|
| PUT | `/conversations/{id}/settings` | `{"pinned"?: bool, "muted"?: bool}` | 置顶 / 取消置顶、免打扰 / 取消免打扰；没给的项不变 |
| POST | `/conversations/{id}/clear` | 无 | 清空聊天记录，会话留在列表里 |
| DELETE | `/conversations/{id}` | 无 | 删除会话：清空聊天记录 + 移出列表 |

三个接口都返回该会话当前的设置：

```json
{ "conversation_id": 12, "peer_user_id": "u1002", "pinned": true, "pinned_at": "2026-11-24 10:00:00",
  "muted": false, "clear_seq": 0, "unread": 3, "visible": true }
```

| 字段 | 说明 |
|---|---|
| peer_user_id | 对方 user_id，客服会话为 `@cs` 或 `@cs:<主体标识>` |
| pinned / pinned_at | 是否置顶、置顶时间；未置顶为 `false` / `null` |
| muted | 是否免打扰 |
| clear_seq | 清空到的序号，`seq <= clear_seq` 的消息本人看不到；没清空过为 `0` |
| unread | 该会话未读数 |
| visible | 是否出现在本人会话列表里；删除后为 `false`，有新消息时恢复为 `true` |

**置顶**：每个用户最多 50 个，超出回 400 `VALIDATION`（「置顶会话最多 50 个」）。重复置顶是幂等的，不刷新 `pinned_at`。只有出现在列表里的会话能置顶，给已删除的会话置顶回 404 `VALIDATION`「会话不存在」。

**免打扰**：

- 会话自己的 `unread` 照常计数，但不计入总未读 `GET /unread`（§5.5）与 after_send 的 `to_unread_total`（§8.2）。
- 长连接的 `message` 推送不受影响，App 在前台照样收到，是否响铃、弹提示由客户端按 `muted` 决定。
- after_send 照常回调，带 `to_muted: true`，由接入方据此不发离线推送（§8.2）。
- 删除会话不会重置免打扰。

**清空**：`clear_seq` 与 `read_seq` 推到该会话最新一条，之后拉消息只返回 `seq > clear_seq` 的消息（§5.3）；会话留在列表原位，`last_message` 为 `null`、`unread` 为 `0`。

**删除**：在清空的基础上移出会话列表、取消置顶，免打扰保留。该会话之后**有任何新消息**（不管哪一方发的）就会自动重新出现，只能看到新消息，需要的话重新置顶。

- 两项都不给 → 400 `VALIDATION`（「pinned 与 muted 至少给一个」）；`{id}` 不合法 → 400 `VALIDATION`；不是会话成员（或会话不存在）→ 403 `FORBIDDEN`。
- 每次成功都会向**本人所有在线设备**（含发起设备）推一条 `conversation_changed`（§6），值没有变化也会推。接入方后端用 §4.9 的接口改设置时同样会推。

**客户端本地处理**（`conversation_changed` 推送、上面三个接口的返回值、§5.11 的每一项，都是同一个对象，按同一套规则应用）：

1. 用整个对象覆盖本地的会话设置，不要按 `action` 推算。
2. `visible` 为 `false`（已删除）：从本地会话列表移除，并**删除本地该会话的全部消息**，否则会话重新出现时旧消息会跟着出来。
3. `clear_seq` 比本地大：删除本地 `seq <= clear_seq` 的消息；会话预览若是其中一条，也一并清空。
4. 本地入库时丢弃 `seq <= clear_seq` 的消息，避免清空之前发出的补拉请求晚到、把旧消息写回来。

### 5.11 会话设置增量补齐 `GET /conversations/changes?cursor=&limit=`

`conversation_changed` 推送会因设备离线而丢失，而会话列表只返回可见的会话，**不能从「列表里没有」推断出「已删除」**。所以每次连上长连接后（冷启动与断线重连都算），按上次保存的游标调一次本接口，把离线期间错过的设置补齐。

返回本人改过设置（置顶、免打扰、清空、删除任一项）的会话的**当前**设置，包括已删除的会话（`visible: false`），按修改时间升序：

```json
{ "items": [
    { "conversation_id": 12, "peer_user_id": "u1002", "pinned": false, "pinned_at": null,
      "muted": false, "clear_seq": 37, "unread": 0, "visible": false }
  ],
  "next_cursor": "MTc2MzYwNDAwMA", "has_more": false }
```

| 参数 | 说明 |
|---|---|
| cursor | 上次返回的 `next_cursor`；第一次不传，返回全部改过设置的会话。不合法 → 400 `VALIDATION` |
| limit | 默认 100，最大 200（超出按 200） |

- `has_more` 为 `true` 时，用本次的 `next_cursor` 继续翻；为 `false` 时把 `next_cursor` **持久化保存**，下次对账带上。
- 游标对客户端不透明，原样保存、原样传回。没有新修改时 `next_cursor` 原样返回传入值（第一次就没有任何记录时为空串，下次照样不传即可）。
- **同一秒内的修改可能重复返回**，按 `conversation_id` 整行覆盖即可，重复应用不会出错。
- 每项都是**当前状态**，不是变更历史：同一会话先清空再删除，只会看到删除后的状态。
- 会话因新消息重新出现**不算**设置修改，不会出现在这里，靠 `message` 推送与会话列表（§5.2）感知。

### 5.12 撤回自己的消息 `POST /messages/{id}/recall`

无请求体，返回撤回后的消息对象。

- 只能撤回**本人发的**、且在站点的撤回时限内的消息。时限由 IM 后台「IM 设置」配置，0 表示没开启（默认），客户端从 `/me` 的 `features.recall_minutes` 取，据此决定是否显示「撤回」。时间以服务端为准。
- 没开启、超过时限 → `IM_RECALL_NOT_ALLOWED`；不是本人发的或不存在 → 404 `VALIDATION`；太频繁 → `IM_RATE_LIMITED`。
- 已撤回的再调返回同一结果，不再推送、不再回调。对方把你拉黑后仍可撤回。
- 撤回后，所有接口、推送里这条消息都变成 `type: "recalled"`（§3），会话预览变成 `[消息已撤回]`；`seq` 不变，**未读数不因撤回减少**。
- 双方所有在线设备都会收到 `message_recalled` 推送（§6），离线的用 §5.13 补齐。收到后把本地这条消息的内容、预览、已下载的图片、语音、文件与视频一起替换或删掉；**撤回不可逆**，之后拿到的旧版本（如在途的拉消息结果）不要再覆盖回去。
- 撤回前已经签出去的图片、语音、文件、视频链接在约 24 小时有效期内仍能打开。
- **旧版客户端不认识撤回**：对方装的是旧版时仍能看到原文。请等客户端都升级后再让站点打开。

### 5.13 撤回增量补齐 `GET /recalls?cursor=&limit=`

撤回不产生新的 seq，离线期间被撤回的消息按 `after_seq` 补拉拿不到，用这个接口补齐（流程见 §7）。

```json
{ "items": [ { "conversation_id": 12, "message_id": 1024, "seq": 37, "message": { 撤回后的消息对象 } } ],
  "next_cursor": "MTc2MzYwNDAwMA", "has_more": false }
```

- 用法同 §5.11：第一次不传 `cursor`（返回全部），之后传上次的 `next_cursor`（持久化保存）；`has_more` 为 `true` 时接着翻；没有新的时 `next_cursor` 原样返回。
- 最近几秒的可能重复给，按 `message_id` 覆盖即可。`limit` 默认 100、最大 200。本人清空过的不返回。
- **只更新本地已有的消息和会话预览**，本地没有的不用插入，拉到时自然是撤回后的形态。

### 5.14 对方已读

站点在「IM 设置」打开「显示对方已读」后（`/me` 的 `features.read_receipt`）：

- 会话列表的单聊项带 `peer_read_seq`，自己发的 `seq <= peer_read_seq` 的消息即对方已读；对方读到新的位置时推 `peer_read`（§6）。
- 只有对方**标已读**（§5.4）会推进它。清空、删除会话、一键清未读、对方发消息都不算看过，所以**打开会话、收到新消息时都要标已读**，哪怕本地未读已经是 0。
- 离线漏掉的 `peer_read` 没有单独的补齐接口，以会话列表里的 `peer_read_seq` 为准。
- 客服会话没有 `peer_read_seq`（用户看不到客服是否已读）；客服坐席能看到用户读到哪条。

### 5.15 正在输入 `POST /conversations/{id}/typing`

无请求体，返回 `{}`。不落库、不回调，只给对方在线设备推一条 `typing`（§6）。

- 输入时**最多每 3 秒调一次**，停止输入不用通知。
- 对方不在线、把你拉黑时同样返回成功。不是会话成员 → 403 `FORBIDDEN`；超频 → `IM_RATE_LIMITED`。这个接口失败都可以忽略。
- 客服会话会告诉正在接待的坐席。网页访客与微信用户不能调（400）。

## 6. 长连接

- 地址：`wss://im.example.com/api/im/v1/connect/websocket`
- 协议：[Centrifuge](https://centrifugal.dev/) 客户端协议（JSON 与 Protobuf 均支持），请用官方 SDK：
  - Flutter：pub 包 `centrifuge`（<https://github.com/centrifugal/centrifuge-dart>），自动走 Protobuf 子协议，无需额外参数
  - Web：npm 包 `centrifuge`（<https://github.com/centrifugal/centrifuge-js>）
- 鉴权：连接时把**用户令牌**作为 SDK 的 `token` 传入（不是 HTTP 头）。
- **不需要、也不允许客户端订阅任何频道**。连上后服务端自动把你订阅到专属频道，所有推送从 SDK 的**服务端订阅 publication 事件**收（Dart：`client.publication`；JS：`centrifuge.on('publication', …)`）。调用 `newSubscription` 会被拒绝。
- 长连接不接收任何业务命令，发消息、标已读都走 HTTP。

**推送事件**（publication 的 data 是 UTF-8 JSON）：

```json
{ "event": "message", "conversation_id": 12, "seq": 37, "message": { 消息对象 } }
{ "event": "read", "conversation_id": 12, "read_seq": 37 }
{ "event": "read_all" }
{ "event": "conversation_changed", "action": "delete", "conversation": { 会话设置对象 } }
{ "event": "message_recalled", "conversation_id": 12, "seq": 37, "message": { 撤回后的消息对象 } }
{ "event": "peer_read", "conversation_id": 12, "peer_read_seq": 37 }
{ "event": "typing", "conversation_id": 12, "from": "u1002", "expires_in": 6 }
```

- `message` 同时推给收发双方的所有在线设备，发送者其他设备借此同步；发送设备自己也会收到，按 `message.id`（或 `client_msg_id`）与 HTTP 返回去重。
- `read` 只推给自己，用于多端同步角标。
- `read_all` 只推给自己的所有在线设备（一键清全部未读，§5.8；发起设备也会收到，可忽略），不带会话信息：收到后把本地各会话未读清零，或重新拉一次会话列表。
- `conversation_changed` 只推给自己的所有在线设备（含发起设备），用于多端同步置顶、免打扰、清空与删除（§5.10）。`action` 为 `settings`（置顶 / 免打扰）/ `clear` / `delete`，`conversation` 是完整的会话设置对象，直接覆盖本地即可，不必按 `action` 推算；本地消息怎么清理见 §5.10「客户端本地处理」。离线时漏掉的用 §5.11 补齐。
- `message_recalled` 推给双方的所有在线设备（含发起设备），按 `message.id` 替换本地那条（§5.12）。本地没有这个会话时忽略，不要因此新建会话。离线时漏掉的用 §5.13 补齐。
- `peer_read` 推给**对方**的所有在线设备，只进不退（§5.14）。
- `typing` 表示 `from` 正在输入，`expires_in` 秒内没有新的、或收到了他的消息就不再显示（§5.15）；客服会话里 `from` 是那个客服的号（`@cs` 或 `@cs:<主体标识>`）。
- 将来可能增加事件，不认识的忽略即可。

**断开码**（SDK 的 disconnected 事件里的 `code`）：

| code | 含义 | SDK 行为 | 你该做的 |
|---|---|---|---|
| 3500 | 令牌无效或过期 | 不自动重连 | 向自家后端换新令牌 → `setToken` → `connect()` |
| 3503 | 被封禁或踢下线 | 不自动重连 | 当作登出，交由自家后端决定是否重新签令牌 |
| 其他（网络断开等） | — | 自动重连，沿用当前令牌 | 等 connected 事件后做一次同步（§7） |

服务端暂时不可用（如数据库抖动）时，连接返回的是 `temporary: true` 的错误（code 100），SDK 会退避自动重连，**不要**当成令牌失效处理。HTTP 接口同理：令牌问题回 401 `IM_TOKEN_INVALID`，服务端暂时故障回 500 `INTERNAL`，只有前者才需要换令牌。

已建立的连接不会因令牌到期被断开，令牌只在每次（重）连时校验。

**Origin 规则**：不带 `Origin` 头的连接（Flutter 等原生 App）直接放行；带 `Origin` 时放行与 IM 域名同源的页面，以及「IM 设置 → 允许的 Origin」里精确匹配的 `scheme://host[:port]`（最多 20 个）。Web 端跨域接入必须先加白名单。

同一份白名单也用于**客户端 HTTP 接口的跨域**（`/api/im/v1/*` 终端用户接口与 `/api/imcs/v1/*`）：白名单内的页面可直接从浏览器调用，预检 `OPTIONS` 回 204 并放行 `Authorization`、`Content-Type` 请求头；白名单外的预检回 403。服务端接口 `/api/im/v1/server/*` 不支持浏览器跨域调用（API Key 不能出现在前端）。

**Dart 最小示例**（`centrifuge: ^0.21.0`）：

```dart
import 'dart:convert';
import 'package:centrifuge/centrifuge.dart' as centrifuge;

Future<centrifuge.Client> connectIm(String token, ImStore store, ImApi api) async {
  final client = centrifuge.createClient(
    'wss://im.example.com/api/im/v1/connect/websocket',
    centrifuge.ClientConfig(token: token),
  );

  // 首连与每次重连成功都对一次账：断线期间的消息靠 HTTP 补齐
  client.connected.listen((_) => syncAll(store, api));

  client.disconnected.listen((e) async {
    if (e.code == 3500) {                       // 令牌失效：找自家后端换
      client.setToken(await fetchImTokenFromYourBackend());
      await client.connect();
    } else if (e.code == 3503) {                // 封禁 / 踢下线
      onImKickedOut();
    }
  });

  client.publication.listen((e) async {          // 服务端订阅的推送，不要自己 subscribe
    final ev = jsonDecode(utf8.decode(e.data)) as Map<String, dynamic>;
    switch (ev['event']) {                        // 不认识的事件忽略即可
      case 'message':
        final convId = ev['conversation_id'] as int;
        final local = store.maxSeq(convId);       // 本地已有的最大 seq，不小于 clear_seq
        if ((ev['seq'] as int) > local + 1) await pullAfter(store, api, convId, local); // 跳号 → 补拉
        store.upsertMessage(ev['message']);       // 按 id 去重，丢弃 seq <= clear_seq 的
      case 'read':
        store.setReadSeq(ev['conversation_id'] as int, ev['read_seq'] as int);
      case 'read_all':
        store.clearAllUnread();
      case 'conversation_changed':
        applyConvSettings(store, ev['conversation'] as Map<String, dynamic>);
      case 'message_recalled':                      // 本地有这个会话才处理；撤回不可逆，旧版本不再覆盖
        store.applyRecall(ev['message'] as Map<String, dynamic>);
      case 'peer_read':
        store.setPeerReadSeq(ev['conversation_id'] as int, ev['peer_read_seq'] as int);
      case 'typing':
        showTyping(ev['conversation_id'] as int, ev['from'] as String);
    }
  });

  await client.connect();
  return client;
}

/// 按 after_seq 补拉直到追平
Future<void> pullAfter(ImStore store, ImApi api, int convId, int afterSeq) async {
  for (var cursor = afterSeq;;) {
    final r = await api.get('/conversations/$convId/messages', {'after_seq': '$cursor', 'limit': '100'});
    final items = (r['items'] as List).cast<Map<String, dynamic>>();
    items.forEach(store.upsertMessage);
    if (items.isEmpty || r['has_more'] != true) break;
    cursor = items.last['seq'] as int;
  }
}

/// 应用一个会话设置对象：conversation_changed 推送与 /conversations/changes 补齐共用（§5.10）
void applyConvSettings(ImStore store, Map<String, dynamic> c) {
  final convId = c['conversation_id'] as int;
  if (c['visible'] != true) {                     // 已删除：会话行与本地消息一起删
    store.deleteConversation(convId);
    return;
  }
  store.deleteMessagesUpTo(convId, c['clear_seq'] as int); // 清空：删 seq <= clear_seq 的消息
  store.updateConvSettings(convId, c);            // 覆盖 pinned / pinned_at / muted / clear_seq / unread
}

/// 补齐离线期间错过的会话设置，syncAll 里拉完会话列表后调用（§7）
Future<void> pullConvChanges(ImStore store, ImApi api) async {
  for (;;) {
    final cursor = store.changesCursor;           // 持久化的游标，第一次为空串
    final r = await api.get('/conversations/changes', {if (cursor.isNotEmpty) 'cursor': cursor, 'limit': '200'});
    for (final c in (r['items'] as List).cast<Map<String, dynamic>>()) {
      applyConvSettings(store, c);
    }
    store.changesCursor = r['next_cursor'] as String; // 应用完再保存
    if (r['has_more'] != true) break;
  }
}
```

## 7. 可靠性与同步

- **MySQL 是唯一真相，推送只是加速。** 推送可能因断网丢失，客户端以 seq 为准自行补齐，不依赖推送必达。
- **断线重连 / 冷启动同步**（`syncAll`）：
  1. 拉 `/conversations`，逐页比对每个会话的 `max_seq` 与本地最大 seq；遇到一整页都已追平即可停止翻页。
  2. 带上次保存的游标调 `/conversations/changes`，翻到 `has_more` 为 `false`，逐项覆盖本地会话设置：离线期间被删除的会话移出列表、被清空的删掉旧消息（§5.11，见上例 `pullConvChanges`）。不能只靠列表判断：列表里没有的会话可能只是还没翻到。
  3. 带上次保存的游标调 `/recalls`，翻到 `has_more` 为 `false`，替换本地已有的消息与会话预览（§5.13）。
  4. 对落后的会话按 `after_seq=<本地最大 seq>` 补拉（见上例）。本地从没拉过的会话，进入时拉最新一页即可，更早的用 `before_seq` 按需翻。清空过的会话，本地最大 seq 取 `max(本地消息的最大 seq, clear_seq)`，否则会反复补拉。
  5. 用列表里的 `unread` / `read_seq` 刷新角标，或调 `/unread` 取总数。
- **跳号检测**：收到 `message` 推送时 `seq > 本地最大 seq + 1`，说明中间漏了，补拉缺的那段（本地最大 seq 同样不小于 `clear_seq`）。
- **未读**：会话未读 = `max_seq − read_seq`，总未读 = 各**非免打扰**会话之和（与 `/unread` 同一口径）。清空与删除会把 `read_seq` 推到最新，所以不再计未读。自己发的消息会把自己的 `read_seq` 推到该条，所以不计入自己的未读。
- **多端同步**：同一用户可多设备同时在线；发出的消息推到自己其他设备，标已读推 `read` 事件、一键清未读推 `read_all` 事件，置顶 / 免打扰 / 清空 / 删除推 `conversation_changed` 事件，各端会话列表与角标一起更新。离线设备漏掉的会话设置用 `/conversations/changes` 补齐（§5.11），漏掉的撤回用 `/recalls` 补齐（§5.13）。
- **发送失败重试**：超时 / 网络错误时沿用同一个 `client_msg_id` 重发，结果以返回的消息对象为准。

## 8. 回调

在「IM 设置」配置：回调地址（http/https，建议 https）、回调密钥（≤128 字符，**务必设置**）、是否开启发送前回调、发送前回调失败策略（放行 / 拒绝，默认放行）、是否推送用户上下线（默认关闭，见 §8.4）、是否识别微信用户（默认关闭，见 §8.6）。

所有回调都是 `POST`，`Content-Type: application/json`，请求头：

| 头 | 说明 |
|---|---|
| `X-Im-Event` | `before_send` / `after_send` / `message_recalled` / `user_state` / `resolve_user` |
| `X-Im-Delivery-Id` | 32 位十六进制投递 id；同一条异步回调任务（after_send / message_recalled / user_state）的每次重试**保持不变**，用于去重 |
| `X-Im-Timestamp` | 发出时刻的 Unix 秒 |
| `X-Im-Signature` | `hex(HMAC-SHA256(回调密钥, 时间戳 + "\n" + 原始请求体))` |

请求体统一为 `{"event": "<事件名>", "data": { … }}`。

### 8.1 before_send（同步）

- 时机：开启发送前回调且配了地址时，每条新消息在通过参数校验、幂等检查与限速之后、**入库之前**调用。服务端代发（§4.5）同样触发，可按 `from` 自行放行。
- 超时 2 秒，不重试。
- `data`：`{from, to, type, content, client_msg_id, from_source, to_source}`（来源取值见 §8.5）；`content` 是规整后的内容（上传图为 `{attachment_id, width, height}`，语音为 `{attachment_id, duration, size, mime}`，文件为 `{attachment_id, name, size, mime}`，视频为 `{attachment_id, duration, width, height, size, mime, cover_attachment_id}`，都不含 ticket 与链接，**看不到文件内容**；要按内容审核，在 after_send 里用链接取）。
- 期望响应：HTTP 200 且

  ```json
  { "code": 0, "data": { "allow": true } }
  { "code": 0, "data": { "allow": false, "reason": "含违规内容" } }
  ```

  `code` 必须是 JSON 数字 `0`。**`allow` 必须显式给 `true`，缺省按拒绝处理。** 拒绝时发送方收到 `IM_MESSAGE_REJECTED`，`reason`（取前 200 字）拼进 `message`。
- 失败（网络错误、超时、非 200、非 JSON、缺 `code`、`code` 非 0）按失败策略：放行则照常发送；拒绝则返回 `IM_MESSAGE_REJECTED`（`消息被拒绝：回调不可用`）。

### 8.2 after_send（异步）

- 时机：配了回调地址即生效（与发送前回调开关无关）。消息入库并推送后写一条投递任务并**立即投递**，通常在秒级内收到；投递进程忙或刚重启时由每分钟一次的定时任务兜底，最坏约 60 秒延迟。幂等重放的消息不回调。
- `data`：

  ```json
  { "message": { 消息对象 }, "conversation_id": 12, "to": "u1002", "to_online": false, "to_muted": false, "to_unread_total": 3,
    "from_source": "app", "to_source": "app" }
  ```

  `from_source` / `to_source` 是收发双方的来源，见 §8.5。
  `to_online` 表示发送时接收方是否至少有一条长连接。上传的图片、语音、文件、视频的 `message.content.url`（视频另有 `cover_url`）约 24 小时有效。
  `to_muted` 表示接收方是否对该会话开了免打扰（§5.10），为 `true` 时建议不发离线推送；`to` 为客服时恒为 `false`；极少数查询失败的情况下该字段缺省，请按「缺省就当没开免打扰」处理。
  `to_unread_total` 是接收方此刻所有**非免打扰**会话的未读之和（**已含这条消息**；接收方对该会话开了免打扰时，这条不计入），推送时可直接用作角标；`to` 为客服时恒为 `0`；极少数统计失败的情况下该字段缺省，请按「缺省就不设角标」处理。
- 成功判定：HTTP 200 且响应体 `{"code": 0}`（`code` 为数字）。
- 失败重试：单次超时 5 秒；第 1 次失败后约 1 分钟重试，第 2 次失败后约 5 分钟重试，第 3 次失败标记为失败、不再自动重试，可在「回调记录」手动重投（重投保持原投递 id）。实际时刻按分钟对齐。
- 请**先落库去重再处理**：以 `X-Im-Delivery-Id` 建唯一键，见过的直接回 `{"code":0}`。

**离线推送建议**：`to_source` 为 `app`、`to_online === false` 且 `to_muted` 不为 `true` 时由接入方向厂商通道（APNs、FCM、各手机厂商）发通知，文字可用会话预览口径（text 取前 50 字、image「[图片]」、voice「[语音]」、file「[文件] 文件名」、video「[视频]」、location「[位置]」、custom 取 `desc`），iOS 的 badge 与 Android 厂商角标可直接用 `to_unread_total`。`to_online` 为 true 但 App 已退到后台时系统可能挂起连接，如需更稳可在 App 端结合前后台状态补本地通知。

### 8.3 验签（PHP）

```php
$secret = getenv('IM_CALLBACK_SECRET');
$body   = file_get_contents('php://input');            // 必须用原始请求体验签，不要先 json_decode 再编码
$ts     = $_SERVER['HTTP_X_IM_TIMESTAMP'] ?? '';
$sig    = $_SERVER['HTTP_X_IM_SIGNATURE'] ?? '';

if (!ctype_digit($ts) || abs(time() - (int) $ts) > 300) {   // 时间窗 5 分钟，防重放
    http_response_code(401); exit;
}
$expect = hash_hmac('sha256', $ts . "\n" . $body, $secret);
if (!hash_equals($expect, $sig)) {                           // 常量时间比较
    http_response_code(401); exit;
}

$deliveryId = $_SERVER['HTTP_X_IM_DELIVERY_ID'] ?? '';
$payload    = json_decode($body, true);
header('Content-Type: application/json');

if ($payload['event'] === 'before_send') {
    $allow = !containsBannedWords($payload['data']);         // 你的审核逻辑，控制在 2 秒内
    echo json_encode(['code' => 0, 'data' => ['allow' => $allow, 'reason' => $allow ? '' : '含违规内容']]);
    exit;
}
if ($payload['event'] === 'after_send') {
    if (!markDeliveryOnce($deliveryId)) {                    // 唯一键插入失败 = 处理过
        echo json_encode(['code' => 0]); exit;
    }
    $d = $payload['data'];
    if (($d['to_source'] ?? 'app') === 'app' && $d['to_online'] === false && empty($d['to_muted'])) {   // 客服、访客与免打扰的会话不推
        queueOfflinePush($d['to'], $d['message']);           // 建议丢队列异步发，尽快返回
    }
    echo json_encode(['code' => 0]);
    exit;
}
if ($payload['event'] === 'user_state') {                    // 打开「推送用户上下线」后才会收到，见 §8.4
    $d = $payload['data'];
    saveOnlineStateIfNewer($d['user_id'], $d['online'], $d['ts']);   // 按 ts 只保留最新状态
}
echo json_encode(['code' => 0]);                             // 不认识的事件也回 code 0，否则会被当成失败反复重试
```

Laravel 中用 `$request->getContent()` 取原始请求体、`$request->header(...)` 取头。

### 8.4 user_state（异步）

- 时机：在「IM 设置」打开「推送用户上下线」且配了回调地址时，终端用户**上线**或**下线**各推一次。坐席连接不推。
  - 上线：该用户从没有连接变为有连接时立即推。
  - 下线：该用户的连接**全部断开 30 秒后仍未重连**才推。30 秒内重连（切网络、进电梯、App 短暂切后台）上线和下线都不推。
- 投递与 after_send 相同：异步、签名、`X-Im-Delivery-Id` 去重、失败重试、可在后台回调记录里查看。
- `data`：

```json
{ "user_id": "u1001", "online": false, "at": "2026-11-23 12:00:00", "ts": 1795392000123, "source": "app" }
```

`at` 为东八区时间；`ts` 为毫秒时间戳，用来判断先后；`source` 是用户来源，见 §8.5，极少数查询失败时缺省。

**按「状态」处理，不要按「切换」处理**：

- 回调只是提醒，**以 §4.8 查询为准**。失败重试可能让上线、下线乱序到达，收到时与你存的 `ts` 比较，旧的直接丢弃。
- **IM 服务重启时不补发下线**：重启前在线的用户收不到下线回调，重连后会再收到一次上线。需要准确状态时调 §4.8 查询。
- 下线回调比实际断开晚约 30 秒，再加投递耗时。
- 开关中途打开：打开前已在线的用户不补发上线，但他们断开时照样会推下线；若断开后 30 秒内重连，会补推一次上线。开关关闭后，已经排队的回调照常投递。

### 8.5 用户来源

| 取值 | 含义 | 出现在 |
|---|---|---|
| `app` | 接入方自己导入的用户 | `from_source` / `to_source` / `source` |
| `visitor` | 网页访客：站点开放网页客服时由站点自己建的匿名用户，**不在接入方的用户体系里** | `from_source` / `to_source` / `source` |
| `wechat` | 公众号 / 小程序客服的用户：站点接了微信渠道时由站点自己建，**不在接入方的用户体系里** | `from_source` / `to_source` / `source` |
| `service` | 客服（`@cs` 与 `@cs:<主体标识>`） | `from_source` / `to_source` |

- 访客与微信用户只能与客服往来（访客能找开放了访客的客服主体，微信用户只有 `@cs`）：普通用户、服务端代发都不能给他们发消息，也不能给他们签令牌、封禁或解封（§4.4 的 `PATCH`），一律回 `IM_USER_NOT_FOUND`；§4.1、§4.2 导入撞上他们的 user_id 时不改资料。要封禁在 IM 后台操作。
- 他们的消息照常走 before_send、after_send（访客还有上下线），内容审核、归档可沿用同一套逻辑；**不要给他们发离线推送**（没有设备；微信的回复由站点发回微信），也不要拿他们的 user_id 去自己的用户表里查。想让坐席知道微信用户是你的哪个会员，实现 §8.6。
- 站点没开放网页客服时不会出现 `visitor`，没接微信渠道时不会出现 `wechat`。字段缺省（旧版本服务端）按 `app` 处理；将来可能增加取值，不认识的按「不是自己的用户」处理。

### 8.6 resolve_user（同步）：微信用户是哪个会员

同一个人在公众号、小程序、App 里是三条独立的客服会话。实现本事件后，坐席接待微信用户时能看到他是你的哪个会员，并能翻看他其他渠道的客服记录与未关闭工单。会话不合并，各回各的。

- 时机：站点接了微信渠道、在「IM 设置」打开「识别微信用户」且配了回调地址时，微信用户发来消息后询问；同一用户 10 分钟内只问一次，坐席也可以手动重新识别。
- 超时 3 秒，不重试，不影响消息收发。失败时保留原来的结果，1 分钟后用户再发消息时再问。
- `data`：

```json
{ "channel": "wechat", "account_type": "oa", "appid": "wx1234567890abcdef", "openid": "oAbc…", "unionid": "oUni…" }
```

| 字段 | 说明 |
|---|---|
| `account_type` | `oa` 公众号 / `mp` 小程序 |
| `openid` | 该用户在这个 `appid` 下的 openid；小程序的与 `code2session` 取到的相同 |
| `unionid` | 公众号绑定了微信开放平台、且取得到时才有，否则为空串；小程序恒为空串 |

- 期望响应：HTTP 200 且 `{"code": 0, "data": {"user_id": "u1001"}}`；不认识、没绑定、已解绑返回空串，站点会清掉已有的关联。
- `user_id` 必须是**已导入**的用户（§4.1）。会员还没进过 IM 的，先导入再返回；返回没导入的按不认识处理。
- **只能返回已确认绑定的会员**：坐席会据此相信对方的身份。不要用昵称、手机号去猜。
- 换绑、解绑后返回新结果即可，站点最迟在 10 分钟后该用户的下一条消息更新；关闭开关会清掉全部关联，用户取消关注时也会删除。
- 请在隐私政策里说明客服会关联用户在各渠道的咨询记录。

### 8.7 message_recalled（异步）

- 时机：配了回调地址即生效。消息被撤回（用户、坐席，或接入方自己调 §4.10）后投递，规则同 after_send。站点没开启撤回时，只有你自己调 §4.10 才会产生。
- `data`（不带原文）：

```json
{ "message_id": 1024, "conversation_id": 12, "seq": 37, "from": "u1001", "to": "u1002", "by": "sender",
  "recalled_at": "2026-11-25 10:00:30", "from_source": "app", "to_source": "app" }
```

- 用来撤掉已发的离线推送、更新你自己的归档。`by` 为 `sender` 发送者 / `agent` 坐席 / `server` 接入方。
- **可能比对应的 `after_send` 先到**（after_send 失败会退避重投，也可能由后台手动重投）：按 `message_id` 记下已撤回，之后再收到它的 `after_send` 就不要推送原文。已经收到的原文服务端收不回。

## 9. 限制与配额

| 项 | 上限 |
|---|---|
| 接入应用调用服务端接口 | 每应用每分钟 600 次、每天 200000 次（进程内计数，按自然分钟 / 自然日清零），超出回 `IM_RATE_LIMITED` |
| 用户发消息 | 每个发送者 10 秒内 20 条（客户端发与服务端代发合并计），超出回 `IM_RATE_LIMITED`；幂等重放不计 |
| 撤回、正在输入 | 各自每个用户 10 秒内 20 次，超出回 `IM_RATE_LIMITED` |
| 撤回时限 | 站点配置，0–1440 分钟，0 = 没开启（默认）；服务端接口撤回不限时 |
| 上传 | 每个用户 10 秒内 20 次；文件与视频另限每人每天 100 个（上传失败的也计）。超出回 `IM_RATE_LIMITED` |
| 文件、视频消息 | 默认关闭；站点分别配置大小上限，1–100MB，0 = 不开启 |
| 网页访客 | 每天发 200 条消息、上传 20 次（图片与文件合计），超出回 `IM_RATE_LIMITED`；只能发文字与上传的图片，站点另外允许后可发文件，不能发视频 |
| 用户资料 | user_id `[A-Za-z0-9_-]{1,64}`；昵称 ≤64 字；头像 ≤512 字符；批量每批 1–100 个 |
| 消息内容 | 见 §5.1 content 约束表（text ≤5000 字、custom.data ≤8KB 等，业务卡片 `im_card` 也计入 data 的 8KB）；上传图片默认 ≤8MB；语音 1–60 秒、≤2MB；视频 1–3600 秒；文件名 ≤100 字 |
| 会话列表 | 每页默认 20、最大 50；首页另含全部置顶会话 |
| 置顶会话 | 每个用户最多 50 个，超出回 400 `VALIDATION` |
| 增量补齐 `/conversations/changes`、`/recalls` | 每页默认 100、最大 200 |
| 黑名单列表 | 每页默认 50、最大 200 |
| 拉消息 | 每页默认 30、最大 100 |
| 令牌有效期 | 默认 168 小时，可配 1–8760 小时 |
| before_send | 超时 2 秒，不重试 |
| resolve_user | 超时 3 秒，不重试；同一微信用户 10 分钟内只问一次 |
| after_send / message_recalled / user_state | 写入即投递，另有每分钟一轮兜底（每轮最多 100 条）；单次超时 5 秒；共 3 次（间隔约 1、5 分钟） |
| 查询在线状态 | 每次 1–100 个 user_id |
| 下线判定 | 连接全部断开 30 秒后仍未重连才算下线并推 user_state |
| Origin 白名单 | 最多 20 个 |
| 消息保留 | 永久保留；撤回的原文只在 IM 后台可查 |

## 10. 客服

站点装了客服模块时，每个用户都有一位固定的联系人「平台客服」，user_id 为 **`@cs`**。用户发给它的消息由后台坐席在客服工作台接待；
坐席回复、欢迎语、排队提示等都以 `@cs` 的身份发回来。对客户端来说，客服就是**一个普通单聊会话**，收发、补拉、已读、未读、推送全部沿用 §5–§7，只多了下面几处约定。

站点没装客服模块时，`@cs` 表现为一个不存在的用户：发给它回 `IM_USER_NOT_FOUND`。

一个站点需要**多个各自接待的客服**（如平台里每家门店一个）时，见 §10.11；下面以平台客服 `@cs` 为例，其余主体同样适用，差别都写在 §10.11。

### 10.1 发起咨询

客户端调 §5.1 发消息，`to` 填 `"@cs"`，其余字段照常（各种消息类型都可以发，上传的图片、语音、文件、视频同样要带 `ticket`）。坐席也能给用户发文件与视频，收到的形状与普通消息相同。

- **只能由用户本人从客户端发**（`Authorization: Bearer <用户令牌>`）。服务端代发（§4.5）的 `from` 或 `to` 是 `@cs` 时一律回 `IM_USER_NOT_FOUND`——接入方后端不能冒充客服，也不能替用户发给客服。
- 发给 `@cs` 的消息同样计入该用户的发消息限速（§9），同样经过 before_send（`data.to` 为 `"@cs"`，可按需放行）。
- 不需要先「建会话」或「申请接入」：发出第一条消息即开始一次接待，后面怎么排队、分给哪位坐席由服务端决定。

### 10.2 会话列表里的形态

客服会话在 §5.2 会话列表里与单聊混排，区别只有：

```json
{ "conversation_id": 88, "type": "service",
  "peer": { "user_id": "@cs", "nickname": "平台客服", "avatar_url": "https://…" },
  "last_message": { "seq": 12, "from": "@cs", "type": "text", "preview": "您好，很高兴为您服务…", "created_at": "2026-11-20 10:00:00" },
  "unread": 1, "max_seq": 12, "read_seq": 11, "last_msg_at": "2026-11-20 10:00:00",
  "pinned": false, "pinned_at": null, "muted": false, "clear_seq": 0 }
```

- `type` 为 `"service"`（普通单聊为 `"c2c"`），**判断是不是客服会话看 `type`**；`peer.user_id` 为 `"@cs"`；`nickname` / `avatar_url` 取站点后台「客服设置」里的客服名称与头像（默认「平台客服」、无头像）。它和普通会话一样按消息时间排序，建议给它单独做入口，或引导用户置顶（§5.10）。
- 每个用户与 `@cs` **只有一条长期会话**，历次咨询的消息都在这一条里按 seq 连续排列，不会因为接待结束换新会话。用户清空或删除后，自己只看得到之后的消息，坐席工作台里的历史不受影响。
- 客服发来的消息 `from` 均为 `"@cs"`，不暴露是哪位坐席回复的。
- **`@cs` 的消息多带一个 `sender_role`**（拉取、推送、回调都有，普通消息没有）：`agent` 坐席回复 / `bot` 机器人回复 / `system` 系统提示。`bot` 的内容由 AI 生成，**界面上要向用户标识**（如「AI 生成」）。将来可能增加取值，不认识的按 `system` 处理。
- **撤回**：用户可以撤回自己发给客服的消息，坐席也可以撤回自己发的（`content.by` 为 `agent`），规则与形态同 §5.12。
- 进入会话、补拉、标已读直接用这条会话的 `conversation_id` 调 §5.3 / §5.4。
- **能置顶、免打扰、清空、删除**，用法同普通会话（§5.10）；接入方后端用 §4.9 的接口时 `{peer_id}` 写 `@cs`。这些只影响用户自己的列表和历史，接待、排队、坐席工作台与接待记录照旧。
- **删除后可能在用户没有任何操作时重新出现**：坐席回复、欢迎语、转接提示、接待超时提示（§10.3）、评价邀请（§10.5）都是 `@cs` 发来的新消息，会让会话自动回到列表。这与「对方发来新消息，会话重新出现」是同一条规则，不必特殊处理。

### 10.3 提示语都是普通消息

以下内容都由服务端以 `@cs` 身份发出的**普通 `text` 消息**，客户端不需要识别、也不需要做任何特殊处理，照常显示即可：

| 时机 | 内容（站点后台可改） |
|---|---|
| 机器人转人工 | 默认「正在为您转接人工客服」 |
| 分配到坐席 | 欢迎语，默认「您好，很高兴为您服务，请问有什么可以帮您？」 |
| 有坐席在线但都满额 | 排队提示，默认「当前咨询人数较多，您前面还有 {n} 位，请稍候。」（`{n}` 已替换为数字） |
| 无坐席在线 | 离线提示，默认「客服暂时不在线，请留言说明问题，我们上线后会尽快回复您。」 |
| 坐席转接 | 「已为您转接其他客服，请稍候」 |
| 接待超时 | 「会话已超时结束，如有问题可随时再次咨询」——接待中双方都沉默超过站点设置的分钟数（默认 10）时自动结束；排队中的咨询不会超时，但站点开启留言后，没有客服在时会转成留言并结束这次排队（§10.9） |

排队期间用户每再发一条，会按当时情况再收到一次排队或离线提示。接待结束后用户再发消息，会自动开始新一次接待（重新排队 / 分配）。

### 10.4 接待状态 `GET /api/imcs/v1/state`

可选。用于在客服会话页顶部显示「排队中，前面还有 N 位」之类的状态条。鉴权与 §5 相同（`Authorization: Bearer <用户令牌>`），路径前缀是 **`/api/imcs/v1`**（不是 `/api/im/v1`）。

```json
{ "status": "queued", "session_id": 305, "queue_position": 2, "agents_online": true, "leave_enabled": false }
```

| 字段 | 说明 |
|---|---|
| status | `none`（当前没有进行中的咨询）/ `bot`（机器人接待中）/ `queued`（排队中）/ `active`（坐席接待中） |
| session_id | 当前这次接待的 id；`none` 时为 `0` |
| queue_position | 排队名次（含自己，排第一位为 `1`）；非 `queued` 时为 `0` |
| agents_online | 是否有坐席在（在线或忙碌）；坐席都满额时仍为 `true`，那是排队 |
| leave_enabled | 站点是否开启了留言（§10.9） |

服务端不推送状态变化。建议在进入客服会话、以及收到 `@cs` 新消息时刷新一次即可。不认识的 `status` 按 `none` 处理。

**机器人与转人工**：站点开了机器人时，新咨询先由机器人回答（`sender_role` 为 `bot`，见 §10.2）。以下情况自动转人工：用户发送转人工关键词（站点后台可配，默认「转人工」「人工客服」）、机器人答不了或调用失败、用户发图片、语音、文件或视频、用量到上限。也可以在 `status` 为 `bot` 时放一个「转人工」按钮，调 `POST /api/imcs/v1/handoff`（无请求体，鉴权同上），返回转完的状态，形状同本接口。机器人接待期间长时间没有新消息会自动结束，不发评价邀请。

### 10.5 评价 `POST /api/imcs/v1/sessions/{id}/rating`

站点开启评价时（默认开启），每次接待结束后服务端会给用户发一条 `custom` 消息作为评价邀请：

```json
{ "from": "@cs", "type": "custom",
  "content": { "data": { "kind": "imcs_rating", "session_id": 305 }, "desc": "请对本次服务进行评价" } }
```

**渲染建议**：识别 `type === "custom" && content.data.kind === "imcs_rating"`，渲染成 1–5 星评分卡片（可附一个评语输入框），提交时调本接口，路径里的 `{id}` 取 `content.data.session_id`。
不认识这种消息的旧版客户端按 custom 的通用口径显示 `desc` 文字即可，不会出错。会话预览与离线推送文字同样是 `desc`。

请求（鉴权同 §10.4）：

```json
{ "rating": 5, "comment": "回复很及时" }
```

| 字段 | 说明 |
|---|---|
| rating | 必填，整数 1–5 |
| comment | 可选，≤200 字 |

成功返回 `{"id": 305}`。每次接待只能评一次，只能评**自己的、已结束的**接待；重复评价、评别人的或未结束的都回 400 `VALIDATION`（`message` 为「无法评价」），评分越界回 400 `VALIDATION`。
客户端可在评价成功、或收到 400「无法评价」后把该卡片置为「已评价」，避免用户反复点。

### 10.6 回调与离线推送

客服消息照常产生 after_send 回调（§8.2），按方向分两种：

| 方向 | `data.message.from` | `data.to` | `data.to_online` | 处理建议 |
|---|---|---|---|---|
| 用户 → 客服 | 用户 user_id | `"@cs"` | 恒为 `false` | **跳过离线推送**：`@cs` 不是真实用户，没有设备可推；坐席端由客服工作台自己提醒。其他客服主体要推员工手机，见 §10.11 |
| 客服 → 用户（坐席回复、提示语、评价邀请） | `"@cs"` | 用户 user_id | 发送时用户是否在线 | 与普通消息相同：`to_online === false` 且 `to_muted` 不为 `true` 时给 `to` 发离线推送，标题可用客服名称，文字用会话预览口径 |

`data.to_muted` 在用户 → 客服方向恒为 `false`，客服 → 用户方向是用户对客服会话的免打扰设置。按 §8.3 的示例改一行即可：

```php
if (($d['to_source'] ?? 'app') === 'app' && !str_starts_with($d['to'], '@cs') && $d['to_online'] === false && empty($d['to_muted'])) {
    queueOfflinePush($d['to'], $d['message']);
}
```

客服发出的消息**不经过 before_send**（坐席是站点自己人），所以 before_send 里只会看到用户发给 `@cs` 的方向。

### 10.7 网页客服

站点自带一个可嵌入的客服窗口，接入方网站放一行脚本即可，不用自己写聊天界面（`im.example.com` 换成你的 IM 站点域名）：

```html
<script src="https://im.example.com/imcs-widget/loader.js" async></script>
```

- **先在后台加白名单**：「客服坐席 → 网页客服 → 允许嵌入的网站」填你的网站来源（如 `https://www.example.com`，不带路径）。不在名单里的网站打不开窗口。
- **没登录的访客**：后台打开「允许没登录的访客咨询」后可用，来源为 `visitor`（§8.5）。身份记在浏览器本地，清除浏览器数据后会变成新访客；同一个人在不同网站域名下是两个访客。访客只能发文字和图片，站点在「IM 设置」允许后可发文件。
- **已登录用户**：你的后端调 §4.3 给该用户签 IM 令牌，交给页面，与该用户在其他端是**同一条**客服会话：

```html
<script>
  window.GuokitCSConfig = {
    token: "后端签的用户令牌",          // 没登录就不传
    onTokenExpired: async () => {        // 令牌过期时回调：换新的再交回来
      GuokitCS.setToken(await fetchImTokenFromYourBackend())
    },
    color: "#2563eb",                    // 可选，按钮颜色
  }
</script>
<script src="https://im.example.com/imcs-widget/loader.js" async></script>
```

找某个客服主体时，配置里加 `service: "主体标识"`（§10.11），窗口的名称、头像、会话都是它的；不填是平台客服。

| 方法 | 说明 |
|---|---|
| `GuokitCS.open()` / `GuokitCS.close()` | 打开 / 收起窗口，可绑到你自己的按钮上 |
| `GuokitCS.setToken(token)` | 登录后传令牌；退出登录传空串，回到访客 |

脚本是异步加载的，调用前先判断 `window.GuokitCS` 是否存在。窗口里机器人的消息标「AI 生成」。站点开启文件消息后，窗口里能发文件；视频只能看，不能发。

**站点部署要求**：反向代理要把 Host（含端口）原样传给 IM 服务，否则窗口里的长连接会被来源校验拒绝；要传真实客户端 IP（`X-Forwarded-For`，且反向代理与 IM 同机），否则所有访客会共用一个新建限额。

**合规提示**：对公众提供 AI 客服前，请由运营方自行确认生成式 AI 服务的备案 / 登记、内容标识与隐私告知义务。

### 10.8 工单进展

站点启用了工单时，坐席可以把一次咨询转成工单，之后的处理进展发到该用户的客服会话，都是普通消息：

| 何时 | 消息 |
|---|---|
| 受理、需要用户补充、已解决、重新处理 | 系统消息（`sender_role` 为 `system`），`custom`，`data.im_card.kind` 为 `ticket`：`title` 是「工单 T…」，`subtitle` 是状态文案，`fields` 里带工单标题；没有图片和链接 |
| 处理人回复、说明要补充什么、写了处理结果 | `text`（`sender_role` 为 `agent`），正文首行是【工单 T…】 |

- 卡片的 `desc` 形如 `[工单] T20261124123456 处理中`，不认识卡片的客户端显示它即可。
- 这些消息照常计未读、触发 after_send（§10.6），离线推送不需要另做。
- 用户要补充信息时直接在客服会话里说，由坐席记进工单。

### 10.9 留言 `POST /api/imcs/v1/leave`

站点启用工单并开启留言后，没有坐席在时，排队中的咨询可以转成留言，由坐席上线后按工单处理（§10.8）。鉴权同 §10.4。

- **自动转**：没有坐席在、且排队超过站点设置的分钟数（默认 10），系统把这次排队转成留言，并发一条提示「已为您登记留言，单号 T…」。什么都不用接。
- **主动留联系方式**：`status` 为 `queued`、`agents_online` 为 `false`、`leave_enabled` 为 `true` 时，可以给用户一个「留联系方式」的表单，提交后立刻转成留言。**留言内容不用另填**，就是用户这次在会话里说的话。

```json
{ "contact_name": "张三", "contact_phone": "13800000000", "contact_email": "" }
```

| 字段 | 规则 |
|---|---|
| contact_name | 选填，≤50 字 |
| contact_phone / contact_email | **至少填一项**；电话为 5–30 位数字、`+`、`-`、空格，邮箱 ≤120 字符 |

成功返回 `{"ticket_no": "T20261124123456"}`，同时发一条带单号的系统消息，这次排队随之结束（`status` 变 `none`）。已经自动转成留言的，再调本接口只更新那张单的联系方式。

| HTTP | code | 含义 |
|---|---|---|
| 400 | `VALIDATION` | 联系方式不合法；有坐席在；用户还没说过话；留言已处理完 |
| 404 | `VALIDATION` | 站点没有启用工单或没有开启留言 |
| 200 | `IM_RATE_LIMITED` | 同一用户每小时最多 5 次 |

转成留言后用户再发消息，会开始新一次咨询；那时仍没人在，再转的内容会补进同一张没处理完的留言。转成留言的咨询没有评价邀请。

### 10.10 微信渠道：回调地址已被占用时的转发

站点可以接公众号与小程序的客服消息：用户在微信里发的话进同一条 `@cs` 客服会话，坐席与机器人的回复发回微信。这些用户的来源是 `wechat`（§8.5），不在你的用户体系里。

用户发的语音是微信的 AMR 格式，站点存成 WAV，以 `voice` 消息（`mime` 为 `audio/wave`）进会话与 after_send。微信不把文件（PDF 等）推给公众号，收不到；用户发的视频显示为「[视频消息，暂不支持查看]」。坐席给微信用户发文件、视频会被拒。

配置在站点后台「微信渠道」完成，微信后台的「消息推送」填站点给的回调地址即可，**接入方不用写代码**。只有一种情况例外：公众号 / 小程序的消息推送地址已经指向你的系统。这时由你的系统转发：

- 把收到的**原始请求原样**再 POST 一次到站点的回调地址：查询串（`signature`、`timestamp`、`nonce`、`encrypt_type`、`msg_signature`）与请求体一字不改。不需要 API Key，报文自带签名。
- 必须是**安全模式**，站点后台填的 Token、EncodingAESKey、AppID 与微信后台一致。
- 你先按微信规则在 5 秒内响应微信，转发异步做，不必等站点返回。站点校验通过回 `success`，校验不通过回 403，暂时出错回 500（可重试；同一条消息重复转发只处理一次，超过 1 小时的不再接收）。
- 站点后台设了**关注自动回复**或**点击菜单的回复**时，站点会直接回用户，你的系统就不要再回同一个事件；没设的一律不回。这两种事件要在 1 分钟内转发到，晚了微信不让回。
- 站点不会用 `force_refresh` 换 token，不影响你自己用 `getAccessToken` 取的 access_token。但同一个用户的 48 小时 5 条额度是两边共用的。

### 10.11 客服主体：一个站点里多个各自接待的客服

平台型业务里，每家门店、每个商户、每个部门都要有自己的客服，由自己的员工接待。每一个这样的客服叫一个**主体**，由你方后端经接口维护；平台客服 `@cs` 是默认主体，照旧在后台配置。需要 IM 服务端 v1.20.0。

| | 默认主体（平台客服） | 其他主体 |
|---|---|---|
| user_id | `@cs` | `@cs:<主体标识>`，如 `@cs:shop_1001` |
| 谁接待 | 站点后台的坐席 | 你方的员工，不需要后台账号 |
| 在哪接待 | 后台客服工作台、桌面端 | 工作台嵌进你方后台，或在你方 App 里打开 |
| 会话 | 每个用户一条 | 每个用户与每个主体各一条，互不相通 |
| 机器人、留言、工单、微信渠道 | 有 | 没有 |

主体之间完全隔离：坐席只看得到本主体的会话、历史、快捷回复，只能转给本主体的坐席。平台管理员在后台能看各主体的接待记录、能停用主体。

#### 用户侧

- 发消息 `to` 填 `@cs:<主体标识>`，其余与发给 `@cs` 完全相同。主体不存在或已停用回 `IM_USER_NOT_FOUND`。
- 会话列表里 `type` 为 `service`、`peer.user_id` 为 `@cs:<主体标识>`，名称头像取主体的。**判断客服会话请看 `type`，不要写死 `=== "@cs"`。**
- 接待状态 `GET /api/imcs/v1/state?service_id=<主体标识>`；评价同 §10.5；转人工与留言不支持，带 `service_id` 调用回 400。`leave_enabled` 恒为 `false`。
- **旧版 App 会把主体会话当成普通单聊显示**，收发不受影响。请等用户升级后再放出入口。

#### 维护主体与坐席

路径前缀 `/api/imcs/v1/server`，鉴权用 `X-Api-Key`，调用频率与 §4 合计。**任一接入应用的 Key 能管全部主体。** 主体标识 `sid` 限 `[a-z0-9_-]{1,40}`，建好后不能改；员工标识 `external_id` 限 `[A-Za-z0-9_.@-]{1,64}`，同一主体内唯一。

| 方法 | 路径 | 请求体 | 说明 |
|---|---|---|---|
| PUT | `/services/{sid}` | `{"name", "avatar_url"?, "settings"?}` | 建或改。没传 `settings` 不改设置，传了整个替换；不改启停 |
| PATCH | `/services/{sid}` | `{"status": 0\|1}` | 停用：用户发不进来，未结束的接待结束，坐席令牌失效并断开 |
| PUT | `/services/{sid}/agents/{external_id}` | `{"nickname", "max_concurrent"?}` | 建或改坐席；移除过的重新启用 |
| DELETE | `/services/{sid}/agents/{external_id}` | 无 | 移除：令牌失效、断开，接待中的转回排队。历史接待里仍显示这名坐席 |
| POST | `/services/{sid}/agents/{external_id}/token` | 无 | 签坐席令牌，返回 `{"token", "expires_at"}` |
| GET | `/services/{sid}/summary` | — | 资料、设置、坐席数 `agents`、在线坐席 `agents_online`、排队 `queue_count` |
| POST | `/services/batch` | `{"services": [{"service_id", "name", …, "agents": [{"external_id", "nickname", …}]}]}` | 首次导入用，每批最多 100 个主体、合计 500 个坐席；遇错即停并指出第几个，可整批重试 |

```bash
curl -X PUT https://im.example.com/api/imcs/v1/server/services/shop_1001 \
  -H "X-Api-Key: imk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" -H "Content-Type: application/json" \
  -d '{"name": "甲店客服", "avatar_url": "https://img.example.com/1.png", "settings": {"visitor_enabled": true}}'
```

`settings` 的各项没给时用站点设置：`welcome_text` / `queue_text` / `offline_text`（≤200 字）、`timeout_minutes`（1–1440）、`rating_enabled`、`visitor_enabled`（允许没登录的网页访客咨询，默认不允许，站点也要打开）。

你方要做的：主体、员工有变动时同步过来；员工离职、门店关停要及时移除或停用。没有坐席的主体照常收消息、排队。

#### 嵌入工作台

先在后台「客服坐席 → 网页客服 → 允许嵌入客服工作台的网站」填你方后台的来源（如 `https://admin.example.com`，不带路径），不在名单里的网站打不开。

```html
<div id="desk" style="height:100vh"></div>
<script src="https://im.example.com/imcs-widget/desk-loader.js"></script>
<script>
  const desk = GuokitDesk.mount("#desk", {
    token: "你方后端签的坐席令牌",
    onTokenExpired: async () => desk.setToken(await fetchDeskTokenFromYourBackend()),
    onUnread: (count) => {},           // 未读数变了，可显示在菜单上
    onRemind: (title, body) => {},     // 页面在后台时来了新消息，由你方弹通知
  })
</script>
```

`desk.setToken(token)` 换员工（传空串退出），`desk.destroy()` 移除。令牌有效 2 小时，页面自动续期；从签发起最长 12 小时，到时回调 `onTokenExpired`。**你方后端签令牌前必须自己确认该员工此刻有权限**，令牌泄露等于对方能以这名员工的身份接待。

**在 App 里接待**（页面适配手机宽度）：用 WebView 打开 `https://im.example.com/imcs-desk#token=<坐席令牌>`，令牌放在 `#` 后面，不会发到服务器日志。页面给 App 的消息走名为 `GuokitDeskHost` 的 JavaScript 通道（`postMessage` 一个 JSON 字符串），`type` 为 `guokitdesk:ready` / `guokitdesk:token-expired` / `guokitdesk:unread`（带 `count`）/ `guokitdesk:remind`（带 `title`、`body`）；App 换令牌执行 `window.GuokitDesk.setToken("…")`。发图片、文件要在 WebView 里放开文件选择。

#### 员工不在线时的提醒

工作台开着时由工作台提醒。没开时要推员工手机，靠 after_send（§8.2）：主体相关的消息 `data` 多带

| 字段 | 说明 |
|---|---|
| service_id | 主体标识；两个方向都有，默认主体没有 |
| agents_online | 用户 → 主体方向：此刻在线的坐席数 |
| agent_external_id | 用户 → 主体方向：正在接待这位用户的员工，没有为空串 |
| agent_online | 用户 → 主体方向：该员工是否在线 |

建议：`agent_external_id` 非空且 `agent_online` 为 `false` 时推那名员工；为空且 `agents_online` 为 `0` 时推该主体的全部员工。极少数查询失败的情况下后三项缺省，按 `0`、空串、`false` 处理。主体发给用户的消息，离线推送与普通客服消息相同。

## 11. SDK、接口规范与 AI 接入

公开仓库 <https://github.com/guokit/guokit-im-sdk> 提供 SDK、机器可读的接口规范与 AI 接入材料：

- **Flutter 客户端 SDK** `guokit_im`（`flutter/`）：令牌续期、断线对账补拉、本地消息缓存（iOS / Android 用 SQLite，Web 用内存）、发送重试与去重、图片上传与链接过期重拉，本文 §6、§7 的规则它都已实现。0.5.0 起提供会话设置 `setPinned` / `setMuted` / `clearConversation` / `deleteConversation`，并自动处理 `conversation_changed` 推送与 `/conversations/changes` 补齐（§5.10、§5.11 的本地处理规则不用自己写）。0.7.0 起提供留言 `leaveCs` 与 `ImCsState.canLeave`（§10.9）。0.8.0 起提供撤回 `recall`、语音 `sendVoice` / `voiceUrl`、对方已读 `peerReadSeq`、正在输入 `sendTyping` / `onTyping`，并自动处理 `message_recalled` 推送与 `/recalls` 补齐（§5.12–§5.15）。0.9.0 起提供文件与视频 `sendFile` / `sendVideo`（按路径发时边读边传）、`fileUrl` / `videoUrl` / `videoCoverUrl` 与上传进度 `onSendProgress`（§5.1、§5.6，需要服务端 v1.19.0）；选文件、压缩转码、截封面、播放、下载由 App 自己做。0.10.0 起提供客服主体 `csUserId` / `ImConversation.serviceId` 与 `csState(serviceId: …)`（§10.11，需要服务端 v1.20.0）。
- **PHP 服务端 SDK** `guokit/im`（根目录 `composer.json`，代码在 `php/`）：本文 §4 的全部服务端接口与 §8 回调验签，PHP ≥ 8.0。
- 两者先以 git 依赖分发，安装方式见仓库 README。

- **OpenAPI 3.1 规范**：`spec/openapi.yaml`，覆盖本文的服务端与客户端接口，可直接导入 Postman、Apifox 等工具生成请求集合或代码。
- **给 AI 编码助手的说明**：`llms.txt`（索引）与 `llms-full.txt`（完整内容），可喂给 AI 助手作为接入上下文。
- **Agent Skill**：`skills/guokit-im`，Claude Code、Codex、Cursor 等可安装，装法见仓库 README。
