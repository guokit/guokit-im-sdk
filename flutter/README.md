# guokit_im · Flutter 客户端 SDK

guokit IM 的 Flutter 客户端：替你处理令牌续期、断线对账补拉、本地消息缓存、发送重试与去重、图片上传与链接过期重拉。
对外只暴露 Dart 自带的 `Stream`，不绑定任何状态管理库。

- iOS / Android：本地缓存用 SQLite（每个用户一个库文件）。
- Web：只做内存缓存，能收发，刷新页面后从服务端重拉。
- 需要 IM 服务端 ≥ v1.8.0。

## 安装

```yaml
dependencies:
  guokit_im:
    git:
      url: https://github.com/guokit/guokit-im-sdk.git
      path: flutter
      ref: v0.5.0
```

## 上手

```dart
import 'package:guokit_im/guokit_im.dart';

final im = GuokitIm(ImConfig(
  baseUrl: 'https://im.example.com',
  // 向自家后端取令牌（后端用 API Key 调 IM 服务端「签令牌」接口）。客户端绝不持有 API Key。
  tokenProvider: () async {
    final r = await myBackend.get('/im/token');       // 后端透传 {token, expires_at}
    if (r.isBanned) throw const ImKickedOutException('账号已封禁');
    return ImToken.fromServer(r.data);
  },
));

await im.login('u1001');                 // 登录成功后（自家账号体系）调用
im.onNewMessage.listen((m) { /* 新消息（含本人在其他设备发出的） */ });
im.onMessageUpdated.listen((m) { /* 本设备发出的消息状态变化 */ });
im.onConversationsChanged.listen((list) { /* 会话列表快照 */ });
im.onTotalUnreadChanged.listen((n) { /* 角标 */ });
im.onKickedOut.listen((_) { /* 被封禁或踢下线：走登出 */ });

final convs = await im.conversations();
final msgs = await im.messages(convs.first.id);   // 本地优先，缺的段自动从服务端补齐
final r = await im.sendText('u1002', '你好');      // 发送失败不抛异常，看 r.status / r.errorCode
await im.markRead(convs.first.id);
await im.logout();                       // 退出账号时调用；clearCache: true 会删本地库
```

完整可运行示例见 [example/](example/)。

## API 一览

| 成员 | 说明 |
|---|---|
| `login(userId)` / `logout({clearCache})` | 打开本地库、取令牌、连接、对账 / 断开并关库。取令牌失败不抛异常，只报 disconnected；已登录同一用户时再调一次即重连 |
| `currentUserId` / `totalUnread` / `connectionState` | 同步取值 |
| `onNewMessage` | 新入库的消息：别人发来的，以及本人在其他设备发出的。本设备发出的不走这里 |
| `onMessageUpdated` | 本设备消息状态变化（发送中 → 成功 / 失败 / 被拒收）、图片换新链接 |
| `onConversationsChanged` / `onTotalUnreadChanged` | 会话快照（置顶在前，其余按最后消息时间倒序）/ 总未读（不计免打扰会话，登录后先推一次本地值） |
| `onConnectionChanged` / `onKickedOut` | 连接状态 / 被封禁或踢下线 |
| `conversations()` | 先返回本地快照，后台再对齐服务端 |
| `messages(convId, {before, limit})` | 按 seq 升序；最新一页末尾会附上本设备还没发成功的消息 |
| `conversationWith(peerId)` | 只查本地，见下方常见问题 |
| `pendingTo(peerId)` | 发给对方的未确认消息（发送中 / 失败 / 被拒收），还没有会话时聊天页用它显示，失败的可重发 |
| `sendText / sendImage(路径) / sendImageBytes(字节) / sendLocation / sendCustom` | 立即经 `onMessageUpdated` 发出「发送中」；Future 在终态完成，**不抛异常** |
| `resend(failed)` | 只能重发 `failed` 的消息，沿用原 `client_msg_id`，服务端幂等不会重复 |
| `markRead(convId)` / `markAllRead()` | 标已读 / 一键清全部未读 |
| `setPinned(convId, bool)` / `setMuted(convId, bool)` | 置顶（最多 50 个）/ 免打扰（不计入总未读），多端同步 |
| `clearConversation(convId)` / `deleteConversation(convId)` | 清空本人这一侧的记录 / 删除会话（同时清空），见下方常见问题 |
| `block / unblock / blocks` | 黑名单 |
| `csState()` / `rateCs(sessionId, rating, {comment})` | 平台客服的接待状态（排队名次）/ 评价一次已结束的接待，见下方常见问题 |
| `imageUrl(msg)` | 返回可用的图片地址；上传图链接约 24 小时过期，SDK 会在快过期时重拉 |

**发送结果**（`ImMessage.status` 与 `errorCode`）：

| 状态 | 情况 | 建议 |
|---|---|---|
| `sent` | 成功 | — |
| `rejected` | `IM_BLOCKED`（对方拉黑了你）、`IM_MESSAGE_REJECTED`（审核拒绝） | 提示「被对方拒收」，不要重发 |
| `failed` | `NETWORK`、`IM_RATE_LIMITED`、服务端 5xx | 允许用户点「重发」 |
| `failed` | `IM_USER_NOT_FOUND`、`IM_USER_DISABLED`、`VALIDATION` | 按错误码提示，例如「对方还不能接收私信」 |
| `failed` | `IMAGE_DECODE`、`FILE_READ`、`IMAGE_MISSING`、`KICKED_OUT`、`UNKNOWN` | SDK 自己的错误码，见 `lib/src/sender.dart` 文件头 |

## 常见问题

**令牌过期、被踢下线怎么处理？**
令牌失效时 SDK 会自动再调 `tokenProvider` 换新，并发请求只换一次。在线时被封禁或踢下线，SDK 收到通知后发 `onKickedOut`，并停止重连。
离线期间被封或被踢，下次连接时只会表现为令牌失效，所以要靠自家后端：发现用户已封禁或已登出时，`tokenProvider` 抛 `ImKickedOutException`，SDK 同样发 `onKickedOut`。

**打开聊天页时还没有会话，对方的昵称头像从哪来？**
IM 不提供查他人资料的接口，资料归你的业务系统，聊天页用自家接口展示。
`conversationWith(peerId)` 只查本地，返回 null 不一定代表没有会话（也可能还没同步到）。直接发消息就行，服务端会自动建会话。
还没有会话时，用 `pendingTo(peerId)` 取发给对方的发送中 / 失败消息显示出来；第一条就发失败的，可以在这里看到并 `resend`。

**连不上、一直 disconnected？**
网络断开这类情况由 SDK 自动重连，连上后会对账补拉。但下面两种情况 SDK **不会自己重试**：
- 取令牌失败（`tokenProvider` 抛了 `ImKickedOutException` 以外的异常，比如冷启动没网）；
- 连续换令牌后服务端仍判定令牌无效。

这时 `onConnectionChanged` 会停在 disconnected，但不会收到 `onKickedOut`。请在网络恢复或 App 回到前台时再调一次 `login(userId)`，已登录同一用户时它只做重连。期间发出的消息会标 `failed`（`NETWORK`），可以重发。

**置顶、免打扰、清空、删除会话怎么用？**
都只影响本人，对方不知道；在一台设备上改，其他设备通过推送和对账同步。需要 IM 服务端支持会话设置接口，旧版服务端上调这四个方法会抛 `ImApiException`。
- 免打扰：`ImConversation.muted` 为 true，`unread` 照常计数（可显示成小红点），但不计入 `totalUnread`
- 清空：会话留在原位，`lastMessage` 为 null、未读为 0；本设备还没发成功的消息（发送中 / 失败）仍在
- 删除：会话从列表消失，历史一并清空，免打扰保留。之后有新消息时会话自动重新出现，只能看到新消息。客服会话在坐席回复、欢迎语、转接提示、接待超时提示、评价邀请时也会重新出现

**平台客服的状态条和评价卡片怎么做？**
客服就是对方为 `@cs` 的会话（`type` 为 `service`），收发与普通单聊相同。
- 状态条：进入客服会话、收到 `@cs` 新消息时各调一次 `csState()`，`status == ImCsStatus.queued` 时显示「前面还有 `queuePosition - 1` 位」。服务端不推送状态变化
- 评价卡片：消息满足 `type == 'custom' && content['data']['kind'] == 'imcs_rating'` 时渲染成 1–5 星卡片，提交调 `rateCs((content['data']['session_id'] as num).toInt(), rating, comment: …)`；评分越界或评语超过 200 字时 SDK 直接抛 `ArgumentError`，请在输入框限住字数。评价成功，或抛 `ImApiException`（`code == 'VALIDATION'`，即「无法评价」：已评过或接待未结束）时，都把卡片置为「已评价」

**图片显示不出来？**
上传图的链接每次读取时现签，约 24 小时有效，不要长期保存链接。显示前调 `imageUrl(msg)`：快过期时 SDK 会重拉，并把新消息经 `onMessageUpdated` 发出。
发送中 / 失败的上传图还没有会话可重拉，`imageUrl` 返回上传时的临时链接；按路径发的图在本机优先用 `msg.localPath` 显示。
外链图（发送时只给了 `url`）原样返回，不会过期。

**Web 端要注意什么？**
- 页面和 IM 不同源时，要在 IM 后台「IM 设置 → 允许的 Origin」加上页面源（如 `https://www.example.com`），否则接口和长连接都会被浏览器拦下。
- Web 拿不到文件路径，发图片用 `sendImageBytes`。
- 字节版图片发送失败后，字节只在内存里。刷新页面或重新登录后，这条无法重发（`IMAGE_MISSING`）。
- Web 只缓存在内存里，刷新页面会重新从服务端拉。

**自定义消息怎么发？**
`sendCustom(to, data, desc)` 的 `data` 必须是 JSON 对象（Map），不能是字符串或数组。`desc` 用作会话预览和离线推送文字。

**业务卡片（订单、商品这类）怎么发、怎么显示？**
在 `sendCustom` 的 `data` 里带一个 `im_card` 对象，客服工作台和各端就能照同一份规范渲染成卡片：

```dart
await im.sendCustom('@cs', {
  'order_id': 1,                          // 你自己的业务字段照旧放
  'im_card': {
    'kind': 'order',                      // order / product / service / article / page
    'title': '订单 #20261123001',           // 唯一必填
    'subtitle': '待发货',
    'fields': [{'label': '金额', 'value': '¥99.00'}],   // 最多 6 行
    'web_link': 'https://shop.example.com/order/1',
    'app_link': 'myapp://order/1',
    'mp_path': '/pages/order/detail?id=1',
  },
}, '[订单] 订单 #20261123001');            // desc 照旧必填，用于预览、推送和兜底
```

- 链接按端取：网站、H5、客服工作台用 `web_link`（https）；原生 App 用 `app_link`；小程序用 `mp_path`，跳到别的小程序再加 `mp_appid`。小程序要打开 `web_link`，得先在小程序后台把域名配成「业务域名」
- 收到时用 `msg.card`（`ImCard?`）渲染：不是 custom、没带卡片或卡片缺 `title` 时为 null，退回显示 `desc`（格式由服务端发送时把关）
- 卡片不合规范时服务端整条拒收，发送结果为 `failed` + `VALIDATION`，`errorMessage` 写明是哪个字段
- `fields` 是发送那一刻的快照，不会随订单状态更新，最新状态以点开详情为准

字段上限与完整规则见接入文档「§5.9 业务卡片」。

**已知限制**
- 对账翻会话列表时只比较 `max_seq`。离线期间在别的设备上标了已读、又不在列表首页的老会话，要等它下次来新消息时未读数才会对齐。
- 已删除的会话（或全新的会话）收到新消息时，SDK 会拉一次会话列表首页取对方资料（首页 = 全部置顶 + 最新的一页非置顶，刚来消息的会话必在其中）。如果这次请求失败，会先显示成昵称和头像为空、未免打扰的占位会话，下次对账时补全。
- 桌面端（macOS / Windows / Linux）没有内置 SQLite 初始化，需要自己通过 `ImConfig(store: …)` 注入存储。自己实现 `ImStore` 的，升到 0.5.0 要补 `clearMessages`、`deleteConversation`、`changesCursor`、`setChangesCursor`，并照接口注释更新合并、排序、总未读规则。
