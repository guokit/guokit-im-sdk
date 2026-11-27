# @guokit/im · JS 客户端 SDK

guokit IM 的客户端 SDK，一套代码用在浏览器、uni-app（微信小程序 / H5 / App）、微信原生小程序。令牌续期、断线重连与对账补拉、消息去重、发送重试、附件上传与链接续期、撤回与已读同步都已包好；界面由你自己写。

| 平台 | 写法 | 状态 |
|---|---|---|
| 浏览器 | 不传 `platform` | 已验证（Chromium） |
| 微信原生小程序 | `platform: uniPlatform(wx)` | 已验证（iOS、安卓真机，开发者工具） |
| uni-app 微信小程序 | `platform: uniPlatform(uni)` | 已验证（开发者工具） |
| uni-app H5 | `platform: uniPlatform(uni)` | 已验证（正式构建，Chromium） |
| uni-app App（iOS / Android）、抖音等小程序 | `platform: uniPlatform(uni)` | 未验证 |
| 支付宝、快手、京东小程序 | — | 不支持：请求接口没有 PUT / DELETE |

需要 IM 服务端 ≥ v1.17.0（文件与视频 ≥ v1.19.0，客服主体 ≥ v1.20.0）。微信小程序基础库 ≥ 2.30.0，更低的要自己转译。

## 安装

还没发 npm，从 [Releases](https://github.com/guokit/guokit-im-sdk/releases) 取：

| 工程 | 用哪个 |
|---|---|
| npm / pnpm（Vite、webpack、uni-app CLI） | `npm i https://github.com/guokit/guokit-im-sdk/releases/download/v0.15.0/guokit-im-0.15.0.tgz`，然后 `import { GuokitIm } from '@guokit/im'` |
| HBuilderX、不用 npm 的 uni-app Vue3 | 把 `guokit-im.esm.js` 放进工程，`import { GuokitIm, uniPlatform } from '@/libs/guokit-im.esm.js'` |
| 微信原生小程序、webpack 工程 | 把 `guokit-im.min.js` 放进工程，`const { GuokitIm, uniPlatform } = require('./guokit-im.min.js')` |
| 浏览器 `<script>` | `guokit-im.min.js`，得到全局 `GuokitIm`（`new GuokitIm.GuokitIm({…})`） |

uni-app Vue3 工程的源码目录里**不要用** `guokit-im.min.js`：Vite 把它当 ESM，导不出东西，还会破坏打包结果。

## 上手

```ts
import { GuokitIm, ImKickedOutError, uniPlatform } from '@guokit/im'

const im = new GuokitIm({
  baseUrl: 'https://im.example.com',
  // 向自家后端取，原样返回签令牌接口的 { token, expires_at }；用户已封禁 / 登出时抛 ImKickedOutError
  tokenProvider: async () => {
    const r = await myApi.imToken()
    if (r.banned) throw new ImKickedOutError()
    return r
  },
  platform: uniPlatform(uni), // 浏览器不传；微信原生小程序传 uniPlatform(wx)
})

im.on('newMessage', m => { /* 别人发来的，以及本人在其他设备发的 */ })
im.on('messageUpdated', m => { /* 发送中 → 终态、换了附件链接、被撤回 */ })
im.on('conversations', list => { /* 会话列表快照，置顶在前 */ })
im.on('totalUnread', n => {})
im.on('kickedOut', () => im.logout())
im.on('friendRequest', r => { /* 有人加我，r.userId 是申请人 */ })
im.on('friendsChanged', list => { /* 好友快照，按 userId 升序 */ })

await im.login('u1001')

const m = await im.sendText('u1002', '你好')           // 失败不抛，看 m.status / m.errorCode
const conv = im.conversationWith('u1002')
if (conv) {
  const page = await im.messages(conv.id)              // 最新一页；更早的传 { before: page[0] }
  await im.markRead(conv.id)                           // 打开会话、会话开着时收到新消息都要调
}
```

- `on()` 返回取消函数，事件在下一拍投递。不要在 `conversations` 事件里再调 `im.conversations()`，它会触发对账。
- 消息、会话都是**普通对象**：时间是毫秒时间戳，没有值的是 `null`，可以直接 `setData` 或交给 Vue / React。每次变化给新对象。
- `conversation.peer` 可能是 `null`（将来没有单一对方的会话），请判空；`type` 将来会增加取值，不认识的消息请兜底显示。
- 会话列表用 `unread` / `totalUnread` 做角标。**打开聊天页一定要调 `messages()`**：没调过的老会话，离线期间来的消息只更新列表，不发 `newMessage`。第一次和某人聊时会话还不存在，先显示 `pendingTo()`，等 `conversations` 事件里出现这个会话再调 `messages()`。

### 发附件

```ts
await im.sendImage(to, file)                                              // 不传宽高时 SDK 自己取
await im.sendVoice(to, file, { durationMs: 3200 })                        // m4a（AAC）或 mp3，60 秒 2MB 内；小程序录音用 mp3
await im.sendFile(to, file, { name: '合同.pdf' })                          // 先看 (await im.features()).fileMaxMb，0 = 不能发
await im.sendVideo(to, file, { durationMs, width, height, cover })        // H.264 的 MP4
```

`file`：浏览器传 `Blob` / `File`（或 `blob:` 路径）；小程序与 App 传 `{ path, name?, size? }`。图片只收 JPEG / PNG / GIF / WebP（不收 HEIC）。文件的扩展名要和内容对得上（对照表见接入文档 §5.6）。上传进度看 `sendProgress`，失败的用 `im.resend(m)`。

显示用 `im.imageUrl(m)` / `voiceUrl` / `fileUrl` / `videoUrl` / `videoCoverUrl`，链接过期会自动续。

### 客服

`csUserId()` 是平台客服号、`csUserId('店铺标识')` 是客服主体，当对方 id 发消息即可。会话 `type === 'service'`，`serviceId` 是主体标识（平台客服为空串）。接待状态 `im.csState({ serviceId })`（不推送，进入会话与收到客服消息时各刷一次）、转人工 `im.handoffCs()`、评价 `im.rateCs(sessionId, 5)`、没人在时留联系方式 `im.leaveCs({ phone })`。`m.isBot` 的内容由 AI 生成，**界面上要标识**。

### 好友

需要服务端 ≥ v1.24.0（接入文档 §5.17）。好友只缓存在内存：`im.friends()` 同步返回快照（冷启动为空）并在后台全量拉一遍，调过之后每次连上都重拉（3000 人最多 6 个请求）；变化走 `friendsChanged`。**每调一次就全量对账一次，别在 render 里调**，进页面调一次、之后听事件。

```ts
const r = await im.addFriend('u1002', '我是张三')     // { status: 'friend' | 'pending', requestId }
const { items } = await im.friendRequests('in')        // 收到的申请；'out' 是发出的
await im.acceptFriend(items[0].requestId)              // 或 rejectFriend（不通知对方）
await im.setFriend('u1002', { remark: '老李', groupIds: [3] })
await im.deleteFriend('u1002')                         // 单向：对方那边我还在，他的 mutual 变 false
```

另有 `friend(userId)`（只查缓存）、`friendGroups` `createFriendGroup` `updateFriendGroup` `deleteFriendGroup`（变化走 `friendGroupsChanged`，收到后重拉）、`setFriendAddPolicy(0 | 1 | 2)`。会话的 `peer.remark` 是好友备注，有就优先显示。`features()` 的 `friendOnly` 为 true 时站点只允许好友互发，给陌生人发会是 `rejected` + `IM_NOT_FRIEND`，`addPolicy` 是本人的加好友方式。

### 其他方法

`pendingTo` `markAllRead` `setPinned` `setMuted` `clearConversation` `deleteConversation` `recall` `sendTyping` `features` `block` `unblock` `blocks` `report` `sendLocation` `sendCustom` `foreground` `logout` `dispose`；工具 `messageCard(m)`（业务卡片）、`csServiceId(userId)`；常量 `reportReasons`（举报原因编码）。完整签名看类型声明。

接口失败 reject `ImApiError`（`code` / `message` / `httpStatus` / `isTemporary`）。`send*` `resend` 例外：发送失败不抛，看消息的 `status`；它们与 `recall` `rateCs` `leaveCs` 的参数错误（`TypeError` / `RangeError`）、未登录是**同步抛**，其余返回 Promise 的方法未登录时 reject。

## 微信小程序要配什么

1. 小程序后台「开发设置 → 服务器域名」四项都加 IM 域名：request、socket（`wss://`）、uploadFile、downloadFile。附件走云存储的，云存储域名也加进 downloadFile。不能用 IP 或 localhost；域名带端口的，`baseUrl` 要逐字一致。
2. 退到后台约 5 秒后系统会挂起小程序，期间收不到消息；回前台 SDK 自动重连并补齐。离线提醒由你的后端在 `after_send` 回调里发订阅消息。
3. 同时最多 5 个 WebSocket，SDK 占 1 个（开发时 uni-app 的日志回显也占）。
4. uni-app App 端收不到前后台事件的，在 `App.vue` 的 `onShow` 里调 `im.foreground()`。

## 浏览器要配什么

- 页面与 IM 不同源时，在 IM 后台「IM 设置 → 允许的 Origin」加页面来源（`scheme://host[:port]`），HTTP 与长连接共用。
- 同源部署时反向代理要原样转发 `Host`（含端口）与 `X-Forwarded-Proto`。
- 附件链接跨域只能给 `<img>` / `<video>` / `<audio>` / 链接用，不能 `fetch`（uni-app H5 的 `downloadFile` 也不行）。

## 限制

- 只有内存缓存：刷新页面、小程序冷启动后从服务端重拉，没发成功的消息会丢；好友同样。`logout()` 清掉全部本地数据。
- 录音、播放、选文件、转码、截封面由你自己做。
- 没有群聊（服务端没有）。

## 排查

| 现象 | 多半是 |
|---|---|
| 一直 `connecting` | 域名没加白：浏览器看 Origin 白名单，小程序看 socket 合法域名；或反代没配 WebSocket。微信小程序握手会带 `Origin`，iOS、安卓真机与开发者工具上都是 IM 自己的来源、不用加白名单 |
| `disconnected` 且控制台有「取令牌或连接失败」 | `tokenProvider` 失败、20 秒没返回，或 `expires_at` 格式不对。恢复网络、回前台时会自动再试 |
| 连上又断、反复换令牌 | 签令牌的站点与 `baseUrl` 不是同一个，或用户被踢下线 |
| `NETWORK` 但网络正常 | 跨域没加白；没装客服的站点跨域调 `csState` 也是它，不要自动循环重试 |
| `BAD_RESPONSE` HTTP 413 | 反向代理的请求体上限小于文件上限 |
| 文件发送报「文件扩展名与内容不符」 | 没传带扩展名的 `name`，或内容真的不对 |

## 示例与开发

`example/browser`（单页）、`example/uni`（uni-app，H5 与微信小程序）。

```bash
npm i && npm test && npm run type-check && npm run build
```
