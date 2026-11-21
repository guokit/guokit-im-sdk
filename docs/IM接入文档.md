# IM 接入文档

本文面向接入方的**后端**与**客户端（App / Web）**开发。一期能力：单聊；文本 / 图片 / 位置 / 自定义四种消息；会话列表；未读与标已读；多端同步；发送前 / 发送后回调。
群聊、撤回、语音、对方已读回执暂不提供。

下文 `https://im.example.com` 代表你的 IM 服务域名，换成实际地址。

## 1. 概览

```
 ┌──────────────┐   REST（X-Api-Key）：导入用户 / 签令牌 / 封禁 / 代发 / 查历史   ┌──────────────┐
 │  接入方后端   │ ───────────────────────────────────────────────────────────▶ │              │
 │              │ ◀─────────────────────────────────────────────────────────── │   IM 服务端   │
 └──────┬───────┘   回调（签名）：before_send（同步） / after_send（异步）        │  （MySQL 为准）│
        │ 登录时把用户令牌下发给 App                                            │              │
 ┌──────▼───────┐   HTTP 上行（Bearer 令牌）：发消息 / 会话 / 已读 / 上传        │              │
 │ 客户端 App/Web│ ───────────────────────────────────────────────────────────▶ │              │
 │              │ ◀─────────────────────────────────────────────────────────── │              │
 └──────────────┘   WebSocket 下行（Centrifuge 协议）：message / read / read_all 事件 └──────────────┘
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
| 200 | `IM_RATE_LIMITED` | 超频：接入应用调用超限，或该用户发消息超限（§9） |
| 403 | `FORBIDDEN` | 客户端访问了自己不在其中（或不存在）的会话 |
| 404 | `VALIDATION` | 服务端审计查询的会话不存在 |
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
| GET | `/conversations/{id}/messages` | 查会话历史（审计） |
| PUT | `/users/{user_id}/blocks/{target}` | 拉黑 |
| DELETE | `/users/{user_id}/blocks/{target}` | 解除拉黑 |
| GET | `/users/{user_id}/blocks` | 黑名单列表 |

### 4.1 导入或更新用户 `PUT /users/{user_id}`

请求 `{"nickname": "张三", "avatar_url": "https://…"}`：`nickname` 可空、≤64 字；`avatar_url` 可空、http(s) 且 ≤512 字符。返回 `{"user_id": "u1001"}`。用户已存在时**只覆盖昵称与头像**（传空串即清空），不改封禁状态、不影响已签令牌。
user_id 不合法 → 400 `VALIDATION`。

### 4.2 批量导入 `POST /users/batch`

```json
{ "users": [ { "user_id": "u1001", "nickname": "张三", "avatar_url": "https://cdn.example.com/a.png" } ] }
```

每批 1–100 个，任一项不合法则**整批拒绝**（`message` 指出第几个），同一事务写入。返回 `{"count": 1}`。

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
注意：服务端拿不到用户的上传凭证，**代发图片请用 `url` 形式**（你自己的 https 图片地址）。

### 4.6 查会话历史 `GET /conversations/{id}/messages`

参数与客户端拉消息相同（§5.3），不校验成员身份。会话不存在 → 404 `VALIDATION`。

### 4.7 黑名单

- **A 拉黑 B 后，B 发给 A 的消息回 `IM_BLOCKED`**（HTTP 200 + 业务码）：消息不落库、不推送、不触发 before_send、不产生 after_send 回调。客户端发与服务端代发（§4.5）都拦截。
- **A 发给 B 不受影响**，拉黑只管「拒收对方」。
- 拉黑前已成功发出的消息，弱网重发（同一 `client_msg_id`）仍返回原消息，不会报被拉黑；被拦的尝试也不占发送限速配额。
- 双方 `user_id` 只校验格式（`[A-Za-z0-9_-]{1,64}`），**不要求已导入**。不能拉黑自己，也不能拉黑 `@cs`，均回 400 `VALIDATION`。
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

## 5. 客户端接口（App / Web 调用）

鉴权：请求头 `Authorization: Bearer <用户令牌>`。路径前缀 `/api/im/v1`。令牌失效统一回 401 `IM_TOKEN_INVALID`，此时向自家后端换新令牌后重试。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/me` | 当前用户 `{user_id, nickname, avatar_url}`，可用作令牌自检 |
| POST | `/messages` | 发消息 |
| GET | `/conversations` | 会话列表（游标分页） |
| GET | `/conversations/{id}/messages` | 补拉 / 翻历史 |
| POST | `/conversations/{id}/read` | 标已读 |
| GET | `/unread` | 总未读 |
| POST | `/upload` | 上传图片 |
| PUT | `/blocks/{target}` | 拉黑 |
| DELETE | `/blocks/{target}` | 解除拉黑 |
| GET | `/blocks` | 黑名单列表 |
| POST | `/conversations/read-all` | 一键清全部未读 |

### 5.1 发消息 `POST /messages`

| 字段 | 类型 | 说明 |
|---|---|---|
| to | string | 接收方 user_id，不能是自己 |
| type | string | `text` / `image` / `location` / `custom` |
| content | object | 按 type，见下表 |
| client_msg_id | string | 必填，1–64 字符，客户端生成的唯一 id |

返回消息对象（含服务端分配的 `id`、`conversation_id`、`seq`）。接收方不存在 → `IM_USER_NOT_FOUND`，已封禁 → `IM_USER_DISABLED`，接收方已把你拉黑 → `IM_BLOCKED`（§5.7）。

**content 约束**（多余字段会被丢弃，落库的是规整后的内容）：

| type | content | 约束 |
|---|---|---|
| `text` | `{"text"}` | 1–5000 字，不能全是空白 |
| `image`（上传图） | `{"attachment_id", "ticket", "width", "height"}` | `attachment_id`、`ticket` 来自 `/upload`，且必须是**发送者本人**上传的；宽高为 1–20000 的整数 |
| `image`（外链图） | `{"url", "width", "height"}` | `url` 为 https 链接，≤1024 字符，原样存取；宽高同上 |
| `location` | `{"lat", "lng", "name", "address"}` | `lat` ∈ [-90, 90]、`lng` ∈ [-180, 180]，必填；`name` ≤100 字、`address` ≤200 字 |
| `custom` | `{"data", "desc"}` | `data` 必须是 JSON **对象**，压缩序列化后 ≤8KB；`desc` 必填，1–100 字，用于会话预览与离线推送文字 |

图片两种形式**二选一**，同时传 `attachment_id` 与 `url` 会被拒。
收到的上传图消息 content 为 `{"attachment_id", "width", "height", "url"}`：`url` 是**每次读取时现签**的临时链接（约 24 小时有效），不要长期保存；本地按 `attachment_id` 缓存图片，链接过期就重新拉一次该消息拿新链接。外链图原样返回 `{"url", "width", "height"}`。

会话预览文字：text 取前 50 字，image 为 `[图片]`，location 为 `[位置]`，custom 取 `desc`。

**client_msg_id 幂等**：同一发送者的 `client_msg_id` 全局唯一（跨会话）。重复提交会直接返回**第一次的那条消息**（code 0，不再推送、不再回调），即使内容不同也以第一次为准。
做法：用户点发送时生成 UUID，随本地「发送中」消息一起保存；超时或断网重试时**沿用同一个**，就不会重复发。

### 5.2 会话列表 `GET /conversations?cursor=&limit=`

- 只列出有过消息的会话，按最后一条消息时间倒序。
- `limit` 默认 20，最大 50（超出按 50）；`cursor` 首页不传，之后传上一页返回的 `next_cursor`；`next_cursor` 为空串表示没有下一页。

```json
{ "items": [ {
    "conversation_id": 12, "type": "c2c",
    "peer": { "user_id": "u1002", "nickname": "李四", "avatar_url": "https://cdn.example.com/b.png" },
    "last_message": { "seq": 37, "from": "u1002", "type": "text", "preview": "晚上见", "created_at": "2026-11-20 10:00:00" },
    "unread": 3, "max_seq": 37, "read_seq": 34, "last_msg_at": "2026-11-20 10:00:00"
  } ],
  "next_cursor": "MTc2MzYwNDAwMDoxMg" }
```

`last_message` 极少数情况下可能为 `null`，请判空。

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

### 5.4 标已读 `POST /conversations/{id}/read`

请求 `{"seq": 37}`（通常传当前看到的最大 seq），返回 `{"read_seq": 37, "unread": 0}`。
已读位置**只进不退**，超过会话最大 seq 时按最大 seq 处理。成功后会向自己所有在线设备推 `read` 事件。

### 5.5 总未读 `GET /unread`

返回 `{"total": 5}`，即该用户所有会话未读之和，可用于 App 角标。

### 5.6 上传图片 `POST /upload`

`multipart/form-data`，字段名 `file`。只收 JPEG / PNG / GIF / WebP（按文件内容识别，不看扩展名），大小上限取站点「图片上限」设置（默认 8MB）。

```json
{ "attachment_id": 5531, "url": "https://im.example.com/files/…", "ticket": "q8Zr…" }
```

`url` 是临时链接，仅供本地预览；发图片消息时带 `attachment_id` + `ticket` + 宽高。`ticket` 与上传者绑定，别人拿去发不出去。

### 5.7 黑名单

语义与 §4.7 相同（对方被你拉黑后发给你的消息回 `IM_BLOCKED`、你发给对方不受影响、幂等、不推送事件），拉黑方是**令牌里的用户**，不需要也不能指定别人。

| 方法 | 路径 | 说明 |
|---|---|---|
| PUT | `/blocks/{target}` | 拉黑，返回 `{}` |
| DELETE | `/blocks/{target}` | 解除，返回 `{}` |
| GET | `/blocks?offset=&limit=` | 列表，按拉黑时间倒序；`limit` 默认 50、最大 200 |

列表返回 `{"items": [{"user_id", "created_at"}], "has_more"}`，同 §4.7。`target` 不合法、是自己或是 `@cs` → 400 `VALIDATION`。

### 5.8 一键清全部未读 `POST /conversations/read-all`

无请求体。把该用户所有会话（含客服会话）的已读位置推到各自最新一条，返回 `{"updated": 3}`，`updated` 是本次实际变更的会话数（没有未读时为 `0`）。
`updated > 0` 时会向自己所有在线设备（含发起这次请求的设备）推**一条** `read_all` 事件（§6），不会逐会话推 `read`。

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
```

- `message` 同时推给收发双方的所有在线设备，发送者其他设备借此同步；发送设备自己也会收到，按 `message.id`（或 `client_msg_id`）与 HTTP 返回去重。
- `read` 只推给自己，用于多端同步角标。
- `read_all` 只推给自己的所有在线设备（一键清全部未读，§5.8；发起设备也会收到，可忽略），不带会话信息：收到后把本地各会话未读清零，或重新拉一次会话列表。

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
    final convId = ev['conversation_id'] as int;
    if (ev['event'] == 'message') {
      final local = store.maxSeq(convId);         // 本地已有的最大 seq
      if ((ev['seq'] as int) > local + 1) await pullAfter(store, api, convId, local); // 跳号 → 补拉
      store.upsertMessage(ev['message']);         // 按 id 去重
    } else if (ev['event'] == 'read') {
      store.setReadSeq(convId, ev['read_seq'] as int);
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
```

## 7. 可靠性与同步

- **MySQL 是唯一真相，推送只是加速。** 推送可能因断网丢失，客户端以 seq 为准自行补齐，不依赖推送必达。
- **断线重连 / 冷启动同步**（`syncAll`）：
  1. 拉 `/conversations`，逐页比对每个会话的 `max_seq` 与本地最大 seq；遇到一整页都已追平即可停止翻页。
  2. 对落后的会话按 `after_seq=<本地最大 seq>` 补拉（见上例）。本地从没拉过的会话，进入时拉最新一页即可，更早的用 `before_seq` 按需翻。
  3. 用列表里的 `unread` / `read_seq` 刷新角标，或调 `/unread` 取总数。
- **跳号检测**：收到 `message` 推送时 `seq > 本地最大 seq + 1`，说明中间漏了，补拉缺的那段。
- **未读**：会话未读 = `max_seq − read_seq`，总未读 = 各会话之和。自己发的消息会把自己的 `read_seq` 推到该条，所以不计入自己的未读。
- **多端同步**：同一用户可多设备同时在线；发出的消息推到自己其他设备，标已读推 `read` 事件、一键清未读推 `read_all` 事件，各端角标一起更新。
- **发送失败重试**：超时 / 网络错误时沿用同一个 `client_msg_id` 重发，结果以返回的消息对象为准。

## 8. 回调

在「IM 设置」配置：回调地址（http/https，建议 https）、回调密钥（≤128 字符，**务必设置**）、是否开启发送前回调、发送前回调失败策略（放行 / 拒绝，默认放行）。

所有回调都是 `POST`，`Content-Type: application/json`，请求头：

| 头 | 说明 |
|---|---|
| `X-Im-Event` | `before_send` / `after_send` |
| `X-Im-Delivery-Id` | 32 位十六进制投递 id；同一条 after_send 任务的每次重试**保持不变**，用于去重 |
| `X-Im-Timestamp` | 发出时刻的 Unix 秒 |
| `X-Im-Signature` | `hex(HMAC-SHA256(回调密钥, 时间戳 + "\n" + 原始请求体))` |

请求体统一为 `{"event": "<事件名>", "data": { … }}`。

### 8.1 before_send（同步）

- 时机：开启发送前回调且配了地址时，每条新消息在通过参数校验、幂等检查与限速之后、**入库之前**调用。服务端代发（§4.5）同样触发，可按 `from` 自行放行。
- 超时 2 秒，不重试。
- `data`：`{from, to, type, content, client_msg_id}`；`content` 是规整后的内容（上传图为 `{attachment_id, width, height}`，不含 ticket 与链接）。
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
  { "message": { 消息对象 }, "conversation_id": 12, "to": "u1002", "to_online": false }
  ```

  `to_online` 表示发送时接收方是否至少有一条长连接。上传图的 `message.content.url` 约 24 小时有效。
- 成功判定：HTTP 200 且响应体 `{"code": 0}`（`code` 为数字）。
- 失败重试：单次超时 5 秒；第 1 次失败后约 1 分钟重试，第 2 次失败后约 5 分钟重试，第 3 次失败标记为失败、不再自动重试，可在「回调记录」手动重投（重投保持原投递 id）。实际时刻按分钟对齐。
- 请**先落库去重再处理**：以 `X-Im-Delivery-Id` 建唯一键，见过的直接回 `{"code":0}`。

**离线推送建议**：`to_online === false` 时由接入方向厂商通道（APNs、FCM、各手机厂商）发通知，文字可用会话预览口径（text 取前 50 字、image「[图片]」、location「[位置]」、custom 取 `desc`）。`to_online` 为 true 但 App 已退到后台时系统可能挂起连接，如需更稳可在 App 端结合前后台状态补本地通知。

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
    if ($d['to_online'] === false) {
        queueOfflinePush($d['to'], $d['message']);           // 建议丢队列异步发，尽快返回
    }
    echo json_encode(['code' => 0]);
}
```

Laravel 中用 `$request->getContent()` 取原始请求体、`$request->header(...)` 取头。

## 9. 限制与配额

| 项 | 上限 |
|---|---|
| 接入应用调用服务端接口 | 每应用每分钟 600 次、每天 200000 次（进程内计数，按自然分钟 / 自然日清零），超出回 `IM_RATE_LIMITED` |
| 用户发消息 | 每个发送者 10 秒内 20 条（客户端发与服务端代发合并计），超出回 `IM_RATE_LIMITED`；幂等重放不计 |
| 用户资料 | user_id `[A-Za-z0-9_-]{1,64}`；昵称 ≤64 字；头像 ≤512 字符；批量每批 1–100 个 |
| 消息内容 | 见 §5.1 content 约束表（text ≤5000 字、custom.data ≤8KB 等）；上传图片默认 ≤8MB |
| 会话列表 | 每页默认 20、最大 50 |
| 黑名单列表 | 每页默认 50、最大 200 |
| 拉消息 | 每页默认 30、最大 100 |
| 令牌有效期 | 默认 168 小时，可配 1–8760 小时 |
| before_send | 超时 2 秒，不重试 |
| after_send | 每分钟投递一轮、每轮最多 100 条；单次超时 5 秒；共 3 次（间隔约 1、5 分钟） |
| Origin 白名单 | 最多 20 个 |
| 消息保留 | 永久保留 |

## 10. 客服

站点装了客服模块时，每个用户都有一位固定的联系人「平台客服」，user_id 为 **`@cs`**。用户发给它的消息由后台坐席在客服工作台接待；
坐席回复、欢迎语、排队提示等都以 `@cs` 的身份发回来。对客户端来说，客服就是**一个普通单聊会话**，收发、补拉、已读、未读、推送全部沿用 §5–§7，只多了下面几处约定。

站点没装客服模块时，`@cs` 表现为一个不存在的用户：发给它回 `IM_USER_NOT_FOUND`。

### 10.1 发起咨询

客户端调 §5.1 发消息，`to` 填 `"@cs"`，其余字段照常（四种消息类型都可以发，上传图同样要带 `ticket`）。

- **只能由用户本人从客户端发**（`Authorization: Bearer <用户令牌>`）。服务端代发（§4.5）的 `from` 或 `to` 是 `@cs` 时一律回 `IM_USER_NOT_FOUND`——接入方后端不能冒充客服，也不能替用户发给客服。
- 发给 `@cs` 的消息同样计入该用户的发消息限速（§9），同样经过 before_send（`data.to` 为 `"@cs"`，可按需放行）。
- 不需要先「建会话」或「申请接入」：发出第一条消息即开始一次接待，后面怎么排队、分给哪位坐席由服务端决定。

### 10.2 会话列表里的形态

客服会话在 §5.2 会话列表里与单聊混排，区别只有：

```json
{ "conversation_id": 88, "type": "service",
  "peer": { "user_id": "@cs", "nickname": "平台客服", "avatar_url": "https://…" },
  "last_message": { "seq": 12, "from": "@cs", "type": "text", "preview": "您好，很高兴为您服务…", "created_at": "2026-11-20 10:00:00" },
  "unread": 1, "max_seq": 12, "read_seq": 11, "last_msg_at": "2026-11-20 10:00:00" }
```

- `type` 为 `"service"`（普通单聊为 `"c2c"`），`peer.user_id` 固定为 `"@cs"`；`nickname` / `avatar_url` 取站点后台「客服设置」里的客服名称与头像（默认「平台客服」、无头像）。建议把它置顶或单独做入口。
- 每个用户与 `@cs` **只有一条长期会话**，历次咨询的消息都在这一条里按 seq 连续排列，不会因为接待结束换新会话。
- 客服发来的消息 `from` 均为 `"@cs"`，不暴露是哪位坐席回复的；不同坐席、系统提示在客户端看来都是「平台客服」。
- 进入会话、补拉、标已读直接用这条会话的 `conversation_id` 调 §5.3 / §5.4。

### 10.3 提示语都是普通消息

以下内容都由服务端以 `@cs` 身份发出的**普通 `text` 消息**，客户端不需要识别、也不需要做任何特殊处理，照常显示即可：

| 时机 | 内容（站点后台可改） |
|---|---|
| 分配到坐席 | 欢迎语，默认「您好，很高兴为您服务，请问有什么可以帮您？」 |
| 有坐席在线但都满额 | 排队提示，默认「当前咨询人数较多，您前面还有 {n} 位，请稍候。」（`{n}` 已替换为数字） |
| 无坐席在线 | 离线提示，默认「客服暂时不在线，请留言说明问题，我们上线后会尽快回复您。」 |
| 坐席转接 | 「已为您转接其他客服，请稍候」 |
| 接待超时 | 「会话已超时结束，如有问题可随时再次咨询」——接待中双方都沉默超过站点设置的分钟数（默认 10）时自动结束；排队中的咨询不会超时 |

排队期间用户每再发一条，会按当时情况再收到一次排队或离线提示。接待结束后用户再发消息，会自动开始新一次接待（重新排队 / 分配）。

### 10.4 接待状态 `GET /api/imcs/v1/state`

可选。用于在客服会话页顶部显示「排队中，前面还有 N 位」之类的状态条。鉴权与 §5 相同（`Authorization: Bearer <用户令牌>`），路径前缀是 **`/api/imcs/v1`**（不是 `/api/im/v1`）。

```json
{ "status": "queued", "session_id": 305, "queue_position": 2 }
```

| 字段 | 说明 |
|---|---|
| status | `none`（当前没有进行中的咨询）/ `queued`（排队中）/ `active`（坐席接待中） |
| session_id | 当前这次接待的 id；`none` 时为 `0` |
| queue_position | 排队名次（含自己，排第一位为 `1`）；非 `queued` 时为 `0` |

服务端不推送状态变化。建议在进入客服会话、以及收到 `@cs` 新消息时刷新一次即可。

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
| 用户 → 客服 | 用户 user_id | `"@cs"` | 恒为 `false` | **跳过离线推送**：`@cs` 不是真实用户，没有设备可推；坐席端由客服工作台自己提醒 |
| 客服 → 用户（坐席回复、提示语、评价邀请） | `"@cs"` | 用户 user_id | 发送时用户是否在线 | 与普通消息相同：`to_online === false` 时给 `to` 发离线推送，标题可用客服名称，文字用会话预览口径 |

按 §8.3 的示例改一行即可：

```php
if ($d['to'] !== '@cs' && $d['to_online'] === false) {
    queueOfflinePush($d['to'], $d['message']);
}
```

客服发出的消息**不经过 before_send**（坐席是站点自己人），所以 before_send 里只会看到用户发给 `@cs` 的方向。

## 11. 接口规范与 AI 接入

公开仓库 <https://github.com/guokit/im-sdk> 提供机器可读的接口规范与 AI 接入材料：

- **OpenAPI 3.1 规范**：`spec/openapi.yaml`，覆盖本文的服务端与客户端接口，可直接导入 Postman、Apifox 等工具生成请求集合或代码。
- **给 AI 编码助手的说明**：`llms.txt`（索引）与 `llms-full.txt`（完整内容），可喂给 AI 助手作为接入上下文。
- **Agent Skill**：`skills/guokit-im`，Claude Code、Codex、Cursor 等可安装，装法见仓库 README。
