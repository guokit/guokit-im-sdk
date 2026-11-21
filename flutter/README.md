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
      url: https://github.com/guokit/im-sdk.git
      path: flutter
      ref: v0.1.0
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
| `login(userId)` / `logout({clearCache})` | 打开本地库、取令牌、连接、对账 / 断开并关库 |
| `currentUserId` / `totalUnread` / `connectionState` | 同步取值 |
| `onNewMessage` | 新入库的消息：别人发来的，以及本人在其他设备发出的。本设备发出的不走这里 |
| `onMessageUpdated` | 本设备消息状态变化（发送中 → 成功 / 失败 / 被拒收）、图片换新链接 |
| `onConversationsChanged` / `onTotalUnreadChanged` | 会话快照（按最后消息时间倒序）/ 总未读（登录后先推一次本地值） |
| `onConnectionChanged` / `onKickedOut` | 连接状态 / 被封禁或踢下线 |
| `conversations()` | 先返回本地快照，后台再对齐服务端 |
| `messages(convId, {before, limit})` | 按 seq 升序；最新一页末尾会附上本设备还没发成功的消息 |
| `conversationWith(peerId)` | 只查本地，见下方常见问题 |
| `sendText / sendImage(路径) / sendImageBytes(字节) / sendLocation / sendCustom` | 立即经 `onMessageUpdated` 发出「发送中」；Future 在终态完成，**不抛异常** |
| `resend(failed)` | 只能重发 `failed` 的消息，沿用原 `client_msg_id`，服务端幂等不会重复 |
| `markRead(convId)` / `markAllRead()` | 标已读 / 一键清全部未读 |
| `block / unblock / blocks` | 黑名单 |
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

**图片显示不出来？**
上传图的链接每次读取时现签，约 24 小时有效，不要长期保存链接。显示前调 `imageUrl(msg)`：快过期时 SDK 会重拉，并把新消息经 `onMessageUpdated` 发出。
外链图（发送时只给了 `url`）原样返回，不会过期。

**Web 端要注意什么？**
- 页面和 IM 不同源时，要在 IM 后台「IM 设置 → 允许的 Origin」加上页面源（如 `https://www.example.com`），否则接口和长连接都会被浏览器拦下。
- Web 拿不到文件路径，发图片用 `sendImageBytes`。
- 字节版图片发送失败后，字节只在内存里。刷新页面或重新登录后，这条无法重发（`IMAGE_MISSING`）。
- Web 只缓存在内存里，刷新页面会重新从服务端拉。

**自定义消息怎么发？**
`sendCustom(to, data, desc)` 的 `data` 必须是 JSON 对象（Map），不能是字符串或数组。`desc` 用作会话预览和离线推送文字。

**已知限制**
- 对账翻会话列表时只比较 `max_seq`。离线期间在别的设备上标了已读、又不在列表首页的老会话，要等它下次来新消息时未读数才会对齐。
- 桌面端（macOS / Windows / Linux）没有内置 SQLite 初始化，需要自己通过 `ImConfig(store: …)` 注入存储。
