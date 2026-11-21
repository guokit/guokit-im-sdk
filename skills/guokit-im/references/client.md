# 客户端参考（App / Web）

> **Flutter 首选 SDK**：[flutter/README.md](../../../flutter/README.md)（`guokit_im`），下面这些状态处理它都已包好。
> 本页的手写片段给暂时没有 SDK 的平台（Web TS 等）参考。

HTTP 前缀 `https://<IM 域名>/api/im/v1`，请求头 `Authorization: Bearer <用户令牌>`。
长连接 `wss://<IM 域名>/api/im/v1/connect/websocket`，Centrifuge 协议，连接时把用户令牌作为 SDK 的 `token`。
字段以 `docs/IM接入文档.md` §5–§7 为准。下面片段只示意正确的状态处理，存储层（`store`）换成你自己的本地库。

## 1. 状态机要点

| 情况 | 识别 | 做法 |
|---|---|---|
| 令牌失效 | HTTP 401 `IM_TOKEN_INVALID`；长连接断开 code 3500 | 向自家后端换新令牌 → `setToken` → 重连 / 重试原请求 |
| 被封禁或踢下线 | 长连接断开 code 3503 | 当作登出，交给自家后端决定是否重新签令牌，**不要自动重连** |
| 服务端暂时不可用 | HTTP 500 `INTERNAL`；长连接 temporary 错误（code 100） | 退避重试，SDK 自动重连；**不要登出** |
| 网络断开 | 其他断开码 | SDK 自动重连；connected 后对账 |
| 被对方拉黑 | 发消息返回 `IM_BLOCKED` | 消息标「被对方拒收」，不重试 |

## 2. 对账与推送（每次 connected 都做）

1. 翻会话列表 `GET /conversations?cursor=`：比对每个会话的 `max_seq` 与本地最大 seq，一整页都已追平即可停。
2. 落后的会话按 `after_seq=<本地最大 seq>` 补拉，`has_more` 为真就用最后一条的 seq 继续。
3. 用列表里的 `unread` / `read_seq` 刷新角标，或 `GET /unread` 取 `total`。

推送事件：

- `message`：`seq > 本地最大 seq + 1` → 先补拉中间段；再按消息 `id` upsert（自己发的也会推回来）。
- `read`：把该会话 `read_seq` 设为事件值（只进不退）。
- `read_all`：所有会话未读清零（或重拉会话列表）。

## 3. 发送

```
点发送 → 生成 client_msg_id（UUID）→ 本地插入「发送中」消息（以 client_msg_id 为键）
       → POST /messages
          ├─ 成功：用返回的消息对象（带 id、seq）替换本地这条
          ├─ 超时 / 网络错误：标「失败」，用户点重发时**沿用同一个 client_msg_id**
          ├─ IM_BLOCKED：标「被对方拒收」
          └─ IM_RATE_LIMITED：稍后重试，同样沿用 client_msg_id
推送回来的同一条消息 → 按 id 合并；若本地还是「发送中」，按 client_msg_id 匹配后替换
```

图片：`POST /upload`（multipart，字段 `file`，只收 JPEG/PNG/GIF/WebP）→ 拿 `attachment_id` + `ticket` →
发 `{"type":"image","content":{"attachment_id":…,"ticket":"…","width":…,"height":…}}`。
收到的上传图 content 带 `url`（约 24 小时有效）：本地按 `attachment_id` 缓存图片文件；加载失败（403/404）时重新拉该消息拿新 `url`。

## 4. Flutter（pub 包 `centrifuge`，默认 Protobuf，publication 的 data 是字节）

```dart
import 'dart:convert';
import 'package:centrifuge/centrifuge.dart' as centrifuge;

Future<centrifuge.Client> connectIm(String token) async {
  final client = centrifuge.createClient(
    'wss://im.example.com/api/im/v1/connect/websocket',
    centrifuge.ClientConfig(token: token),
  );

  client.connected.listen((_) => syncAll());          // 首连与每次重连都对账

  client.disconnected.listen((e) async {
    if (e.code == 3500) {                              // 令牌失效
      client.setToken(await fetchImTokenFromYourBackend());
      await client.connect();
    } else if (e.code == 3503) {                       // 封禁 / 踢下线
      onImKickedOut();
    }
  });

  client.publication.listen((e) async {                // 服务端订阅推送；不要自己 newSubscription
    final ev = jsonDecode(utf8.decode(e.data)) as Map<String, dynamic>;
    switch (ev['event']) {
      case 'message':
        final convId = ev['conversation_id'] as int;
        final local = store.maxSeq(convId);
        if ((ev['seq'] as int) > local + 1) await pullAfter(convId, local);
        store.upsertMessage(ev['message']);            // 按 id 去重
      case 'read':
        store.setReadSeq(ev['conversation_id'] as int, ev['read_seq'] as int);
      case 'read_all':
        store.clearAllUnread();
    }
  });

  await client.connect();
  return client;
}

Future<void> pullAfter(int convId, int afterSeq) async {
  for (var cursor = afterSeq;;) {
    final r = await api.get('/conversations/$convId/messages', {'after_seq': '$cursor', 'limit': '100'});
    final items = (r['items'] as List).cast<Map<String, dynamic>>();
    items.forEach(store.upsertMessage);
    if (items.isEmpty || r['has_more'] != true) break;
    cursor = items.last['seq'] as int;
  }
}
```

HTTP 判定：`r['code'] == 0` 才是成功（数字）；401 时换令牌后重试一次。

## 5. Web（npm 包 `centrifuge`，默认 JSON 协议，publication 的 data 已是对象）

Web 跨域接入前，在 IM 后台「IM 设置 → 允许的 Origin」加上你的页面源（`scheme://host[:port]`），否则握手被拒；原生 App 不带 Origin，不受影响。

```ts
import { Centrifuge } from 'centrifuge';

export function connectIm(token: string) {
  const c = new Centrifuge('wss://im.example.com/api/im/v1/connect/websocket', { token });

  c.on('connected', () => { void syncAll(); });
  c.on('disconnected', async (ctx) => {
    if (ctx.code === 3500) {
      c.setToken(await fetchImTokenFromYourBackend());
      c.connect();
    } else if (ctx.code === 3503) {
      onImKickedOut();
    }
  });
  c.on('publication', async (ctx) => {          // 服务端订阅推送
    const ev = ctx.data as { event: string; conversation_id?: number; seq?: number; read_seq?: number; message?: unknown };
    if (ev.event === 'message') {
      const local = store.maxSeq(ev.conversation_id!);
      if (ev.seq! > local + 1) await pullAfter(ev.conversation_id!, local);
      store.upsertMessage(ev.message);
    } else if (ev.event === 'read') {
      store.setReadSeq(ev.conversation_id!, ev.read_seq!);
    } else if (ev.event === 'read_all') {
      store.clearAllUnread();
    }
  });
  c.connect();
  return c;
}

async function api<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(`https://im.example.com/api/im/v1${path}`, {
    method,
    headers: { Authorization: `Bearer ${currentToken()}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const r = await res.json();
  if (r.code === 0) return r.data as T;          // 成功是数字 0
  if (res.status === 401) throw new TokenInvalidError();   // 换令牌后重试
  throw new ImError(r.code, r.message);          // 业务失败：code 是字符串
}
```

## 6. 平台客服

站点装了客服模块时，`to: "@cs"` 就是给平台客服发消息，客服会话和普通单聊一样出现在会话列表里（`peer.user_id` 为 `@cs`）。
欢迎语、排队提示、坐席回复都以 `@cs` 身份到达；接待状态 `GET /api/imcs/v1/state`，评价 `POST /api/imcs/v1/sessions/{id}/rating`（`{id}` 即评价卡片里的 `session_id`），见接入文档 §10。
