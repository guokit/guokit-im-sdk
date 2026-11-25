import { ImApi, type Raw } from './api.js'
import { Emitter } from './emitter.js'
import { isKickedOut } from './errors.js'
import type {
  ImBlockItem, ImConnectionState, ImConversation, ImCsState, ImFeatures, ImMessage, ImSendProgress, ImToken, ImTyping,
} from './models.js'
import { browserPlatform, isBrowser } from './platform/browser.js'
import type { ImFile, ImPlatform, NetworkChange } from './platform/types.js'
import { CODE_KICKED, CODE_TOKEN_INVALID, createRealtime, webSocketUrl, type Realtime, type RealtimeFactory } from './realtime.js'
import { Sender } from './sender.js'
import { Store } from './store.js'
import { Sync } from './sync.js'
import { TokenManager } from './token.js'

export interface ImConfig {
  /** IM 服务地址，如 `https://im.example.com`。 */
  baseUrl: string
  /** 向自家后端取 IM 令牌，原样返回签令牌接口的 `{ token, expires_at }`。用户已封禁 / 登出时抛 `ImKickedOutError`。 */
  tokenProvider: () => Promise<ImToken> | ImToken
  /** 平台：uni-app 传 `uniPlatform(uni)`，微信原生小程序传 `uniPlatform(wx)`，浏览器不传。 */
  platform?: ImPlatform
}

export interface ImEvents {
  /** 新入库的消息：别人发来的，以及本人在其他设备发的。没打开过（没调过 messages()）的老会话在离线期间来的消息只更新列表，不走这里。 */
  newMessage: ImMessage
  /** 本地消息变化：新建「发送中」、到终态、附件换新链接、变成已撤回。 */
  messageUpdated: ImMessage
  /** 会话列表快照，置顶在前。 */
  conversations: ImConversation[]
  totalUnread: number
  connection: ImConnectionState
  /** 被封禁或踢下线，SDK 已停止重连，请走登出。 */
  kickedOut: undefined
  typing: ImTyping
  sendProgress: ImSendProgress
}

/** 换令牌重连的上限，连上或主动 login 后清零：防止 provider 一直给坏令牌时死循环。 */
const MAX_AUTH_RETRIES = 2
/** 小程序离开这么久再回来，连接多半已断，直接丢掉重连。 */
const AWAY_MS = 10_000
const TYPING_THROTTLE = 3000

/** 一次登录的全部状态。登出整套作废：换号后旧账号的在途请求、回调都落不到新账号上。 */
interface Session {
  me: string
  store: Store
  tokens: TokenManager
  api: ImApi
  sync: Sync
  sender: Sender
  rt: Realtime | null
  rtToken: string | null
  kicked: boolean
  authRetries: number
  /** 本次登录已上报的已读。不能只看 readSeq：一键清未读会把它推满，之后打开聊天也要上报对方才看得到「已读」。 */
  reportedRead: Map<number, number>
  typingTimers: Map<number, ReturnType<typeof setTimeout>>
  typingSent: Map<number, number>
  hiddenAt: number | null
  offs: (() => void)[]
}

export class GuokitIm {
  private emitter = new Emitter<ImEvents>()
  private platform: ImPlatform
  private base: string
  private s: Session | null = null
  private state: ImConnectionState = 'disconnected'
  private unread = 0
  private disposed = false

  /** 测试注入用。 */
  protected realtimeFactory: RealtimeFactory = createRealtime

  constructor(private config: ImConfig) {
    if (!/^https?:\/\//.test(config?.baseUrl ?? '')) throw new TypeError('baseUrl 须以 http:// 或 https:// 开头')
    if (typeof config.tokenProvider !== 'function') throw new TypeError('缺少 tokenProvider')
    if (!config.platform && !isBrowser()) {
      throw new Error('当前不是浏览器，请传 platform：uni-app 用 uniPlatform(uni)，微信原生小程序用 uniPlatform(wx)')
    }
    this.platform = config.platform ?? browserPlatform()
    this.base = config.baseUrl.replace(/\/+$/, '')
  }

  // ---------------- 状态与事件 ----------------

  get currentUserId(): string | null {
    return this.s?.me ?? null
  }

  /** 各非免打扰会话未读之和。 */
  get totalUnread(): number {
    return this.unread
  }

  get connectionState(): ImConnectionState {
    return this.state
  }

  /** 监听事件，返回取消函数。事件在下一拍投递。 */
  on<K extends keyof ImEvents>(event: K, fn: (payload: ImEvents[K]) => void): () => void {
    return this.emitter.on(event, fn)
  }

  private emit<K extends keyof ImEvents>(s: Session, event: K, payload: ImEvents[K]): void {
    this.emitter.emit(event, payload, () => this.s === s)
  }

  // ---------------- 登录 / 登出 ----------------

  /**
   * 取令牌 → 连接，连上后自动对账（不等它完成）。取令牌失败不抛：被踢走 kickedOut，其余报 disconnected。
   * 同一用户已断开时再调一次即重连。
   */
  async login(userId: string): Promise<void> {
    if (this.disposed) throw new Error('已 dispose')
    if (!userId || typeof userId !== 'string') throw new TypeError('userId 须为非空字符串')
    if (this.s && (this.s.me !== userId || this.s.kicked)) this.logout()
    let s = this.s
    if (s) {
      if (this.state !== 'disconnected') return
      s.authRetries = 0
    } else {
      s = this.open(userId)
    }
    await this.connect(s)
  }

  /** 断开并清掉全部本地数据。没发成功的消息随之丢失。 */
  logout(): void {
    const s = this.s
    if (!s) return
    this.s = null
    s.offs.forEach(f => f())
    s.typingTimers.forEach(t => clearTimeout(t))
    s.sync.close()
    s.api.close()
    s.tokens.clear()
    s.rt?.close()
    s.rt = null
    if (this.unread !== 0) {
      this.unread = 0
      this.emitter.emit('totalUnread', 0)
    }
    this.setState('disconnected')
  }

  /** 登出并移除全部监听，之后不能再用。 */
  dispose(): void {
    this.logout()
    this.disposed = true
    this.emitter.clear()
  }

  /** 平台自己监听不到回前台时，由接入方在 App 回到前台时调（如 App.vue 的 onShow）。 */
  foreground(): void {
    if (this.s) this.resume(this.s, true)
  }

  private open(me: string): Session {
    const store = new Store()
    const tokens = new TokenManager(this.config.tokenProvider)
    const api = new ImApi(this.base, tokens, this.platform)
    const sync = new Sync(api, store, me, {
      onNewMessage: m => {
        if (!m.isSelf) this.stopTyping(s, m.conversationId!, m.from)
        this.emit(s, 'newMessage', m)
      },
      onMessageUpdated: m => this.emit(s, 'messageUpdated', m),
      onChanged: () => this.snapshot(s),
      onError: e => isKickedOut(e) && this.kick(s),
      onTyping: (id, from, ttl) => this.showTyping(s, id, from, ttl),
    })
    const sender = new Sender(api, store, sync, this.platform, me, {
      onUpdated: m => this.emit(s, 'messageUpdated', m),
      onSnapshot: () => this.snapshot(s),
      onKickedOut: () => this.kick(s),
      onProgress: p => this.emit(s, 'sendProgress', p),
      closed: () => this.s !== s,
    })
    const s: Session = {
      me, store, tokens, api, sync, sender, rt: null, rtToken: null, kicked: false, authRetries: 0,
      reportedRead: new Map(), typingTimers: new Map(), typingSent: new Map(), hiddenAt: null, offs: [],
    }
    this.s = s
    s.offs.push(
      this.platform.onVisibility(v => this.onVisibility(s, v)),
      this.platform.onNetwork(c => this.onNetwork(s, c)),
    )
    this.snapshot(s, true)
    return s
  }

  // ---------------- 会话与消息 ----------------

  /** 先返回本地快照，同时在后台对一次账（结果走 conversations 事件）。 */
  conversations(): ImConversation[] {
    const s = this.session()
    void s.sync.reconcile()
    return s.store.conversations()
  }

  /** 只查本地。null 可能是还没会话，也可能是还没同步到；聊天页照样可以直接发消息。 */
  conversationWith(peerId: string): ImConversation | null {
    return this.session().store.conversationByPeer(peerId)
  }

  /** 发给对方的未确认消息（发送中 / 失败 / 被拒收）。已有会话时 messages() 的最新一页已带上它们。 */
  pendingTo(peerId: string): ImMessage[] {
    return this.session().store.unconfirmed(peerId).sort(byCreated)
  }

  /**
   * 按 seq 升序的一页，本地优先，不连续或不足时从服务端补。
   * 不传 before（或给未确认消息）是最新一页，末尾附上未确认消息；传了是更早的，不含未确认消息。
   */
  async messages(conversationId: number, opts: { before?: ImMessage | null; limit?: number } = {}): Promise<ImMessage[]> {
    const s = this.session()
    const limit = opts.limit ?? 30
    return this.run(s, async () => {
      const { store, api, sync } = s
      const conv = store.conversation(conversationId)
      const firstSeq = (conv?.clearSeq ?? 0) + 1 // 清空后能看到的第一条
      const beforeSeq = opts.before?.seq

      if (beforeSeq) {
        if (beforeSeq <= firstSeq) return []
        const local = store.messages(conversationId, limit, beforeSeq)
        if (isComplete(local, limit, firstSeq, beforeSeq)) return local
        sync.ingest(conversationId, (await api.messages(conversationId, { beforeSeq, limit })).items, false)
        return store.messages(conversationId, limit, beforeSeq)
      }

      let fetched = false
      let latest = false
      const fetchLatest = async () => {
        fetched = latest = true
        const { items } = await api.messages(conversationId, { limit })
        sync.ingest(conversationId, items, false)
        if (store.syncedSeq(conversationId) > 0) return
        // 清空过、之后没有新消息的会话是空页：起点就是清空到的位置
        store.setSyncedSeq(conversationId, items.length ? items[items.length - 1].seq : firstSeq - 1)
      }
      const synced = store.syncedSeq(conversationId)
      if (synced === 0) await fetchLatest()
      else if (conv && synced < conv.maxSeq) {
        fetched = true
        await sync.pullAfter(conversationId, synced, false)
      }
      let local = store.messages(conversationId, limit)
      if (!latest && !isComplete(local, limit, firstSeq)) {
        await fetchLatest()
        local = store.messages(conversationId, limit)
      }
      const peer = store.conversation(conversationId)?.peer
      const pending = peer ? store.unconfirmed(peer.userId).sort(byCreated) : []
      if (fetched) this.snapshot(s)
      return [...local, ...pending]
    })
  }

  /** 标已读到会话当前最大 seq。打开会话、会话打开着时收到新消息都要调：对方的「已读」只由它推进。 */
  async markRead(conversationId: number): Promise<void> {
    const s = this.session()
    const conv = s.store.conversation(conversationId)
    if (!conv || (conv.readSeq >= conv.maxSeq && (s.reportedRead.get(conversationId) ?? 0) >= conv.maxSeq)) return
    await this.run(s, async () => {
      const readSeq = await s.api.markRead(conversationId, conv.maxSeq)
      s.reportedRead.set(conversationId, conv.maxSeq)
      s.store.setReadSeq(conversationId, readSeq)
      this.snapshot(s)
    })
  }

  /** 一键清全部未读。 */
  async markAllRead(): Promise<void> {
    const s = this.session()
    await this.run(s, async () => {
      await s.api.markAllRead()
      s.store.markAllRead()
      this.snapshot(s)
    })
  }

  /** 置顶最多 50 个，超出抛 ImApiError。多端同步。 */
  setPinned(conversationId: number, pinned: boolean): Promise<void> {
    return this.change(api => api.setSettings(conversationId, { pinned }))
  }

  setMuted(conversationId: number, muted: boolean): Promise<void> {
    return this.change(api => api.setSettings(conversationId, { muted }))
  }

  /** 清空本人这一侧的记录，会话留在列表。 */
  clearConversation(conversationId: number): Promise<void> {
    return this.change(api => api.clearConversation(conversationId))
  }

  /** 删除会话（含本人这一侧的记录）。之后有新消息时会重新出现，只能看到新消息。 */
  deleteConversation(conversationId: number): Promise<void> {
    return this.change(api => api.deleteConversation(conversationId))
  }

  private async change(request: (api: ImApi) => Promise<Raw>): Promise<void> {
    const s = this.session()
    await this.run(s, async () => s.sync.applySettings(await request(s.api)))
  }

  /** 撤回自己发的一条。没开启、超过时限抛 ImApiError（IM_RECALL_NOT_ALLOWED，直接显示 message）。 */
  recall(message: ImMessage): Promise<void> {
    const s = this.session()
    const id = message.id
    if (id === null || message.from !== s.me) throw new TypeError('只能撤回自己已发送的消息')
    return this.run(s, async () => s.sync.applyRecall(await s.api.recall(id)))
  }

  /** 输入框内容变化时调即可，按会话 3 秒节流，失败静默。 */
  async sendTyping(conversationId: number): Promise<void> {
    const s = this.session()
    if (Date.now() - (s.typingSent.get(conversationId) ?? 0) < TYPING_THROTTLE) return
    s.typingSent.set(conversationId, Date.now())
    await this.run(s, () => s.api.typing(conversationId)).catch(() => {})
  }

  /** 站点开关：能不能撤回、显不显示对方已读、能发多大的文件与视频。登录后取一次即可。 */
  features(): Promise<ImFeatures> {
    const s = this.session()
    return this.run(s, () => s.api.features())
  }

  async block(userId: string): Promise<void> {
    const s = this.session()
    await this.run(s, () => s.api.block(userId))
  }

  async unblock(userId: string): Promise<void> {
    const s = this.session()
    await this.run(s, () => s.api.unblock(userId))
  }

  blocks(opts: { offset?: number; limit?: number } = {}): Promise<{ items: ImBlockItem[]; hasMore: boolean }> {
    const s = this.session()
    return this.run(s, () => s.api.blocks(opts.offset, opts.limit))
  }

  // ---------------- 客服 ----------------

  /** 客服接待状态，服务端不推送：进入客服会话、收到客服新消息时各刷一次。serviceId 不传是平台客服。 */
  csState(opts: { serviceId?: string } = {}): Promise<ImCsState> {
    const s = this.session()
    return this.run(s, () => s.api.csState(opts.serviceId))
  }

  /** 转人工（只有平台客服支持）。当前没有机器人接待时什么都不做，返回当前状态。 */
  handoffCs(): Promise<ImCsState> {
    const s = this.session()
    return this.run(s, () => s.api.csHandoff())
  }

  /** 评价一次已结束的接待，sessionId 取评价邀请消息（custom，`data.kind === 'imcs_rating'`）的 `data.session_id`。 */
  rateCs(sessionId: number, rating: number, comment = ''): Promise<void> {
    const s = this.session()
    const text = comment.trim()
    if (!(rating >= 1 && rating <= 5 && Number.isInteger(rating))) throw new RangeError('评分须为 1–5')
    // 在这里拦：服务端超长同样回 VALIDATION，会被当成「已评价」
    if (Array.from(text).length > 200) throw new RangeError('评语不能超过 200 字')
    return this.run(s, async () => void (await s.api.csRate(sessionId, rating, text)))
  }

  /** 没有坐席在时留联系方式，返回单号。电话与邮箱至少填一项。IM_RATE_LIMITED 是每小时 5 次，不要自动重试。 */
  leaveCs(contact: { name?: string; phone?: string; email?: string }): Promise<string> {
    const s = this.session()
    const name = (contact.name ?? '').trim()
    const phone = (contact.phone ?? '').trim()
    const email = (contact.email ?? '').trim()
    if (!phone && !email) throw new RangeError('电话与邮箱至少填一项')
    if (Array.from(name).length > 50) throw new RangeError('称呼不能超过 50 字')
    if (phone && !/^[0-9+\- ]{5,30}$/.test(phone)) throw new RangeError('电话须为 5–30 位数字、+、-、空格')
    if (utf8Length(email) > 120) throw new RangeError('邮箱不能超过 120 字节')
    return this.run(s, () => s.api.csLeave(name, phone, email))
  }

  // ---------------- 发送 ----------------
  //
  // 都返回 Promise<ImMessage>，在终态（sent / failed / rejected）完成，发送失败不抛，看 status 与 errorCode：
  // 服务端错误码，或 NETWORK / BAD_RESPONSE / IMAGE_DECODE / *_MISSING / KICKED_OUT / UNKNOWN。
  // 未登录、参数用错同步抛。

  sendText(to: string, text: string): Promise<ImMessage> {
    return this.session().sender.text(to, text)
  }

  /** 宽高不传时由 SDK 取。只收 JPEG / PNG / GIF / WebP。 */
  sendImage(to: string, file: ImFile, opts: { width?: number; height?: number } = {}): Promise<ImMessage> {
    return this.session().sender.image(to, file, opts)
  }

  /** m4a（AAC）或 mp3，60 秒、2MB 以内；小程序录音用 mp3。录音由接入方做。 */
  sendVoice(to: string, file: ImFile, opts: { durationMs: number }): Promise<ImMessage> {
    return this.session().sender.voice(to, file, opts.durationMs)
  }

  /** 大小上限先看 features().fileMaxMb，0 = 不能发。文件名的扩展名要和内容对得上（接入文档 §5.6）。 */
  sendFile(to: string, file: ImFile, opts: { name?: string } = {}): Promise<ImMessage> {
    return this.session().sender.file(to, file, opts.name)
  }

  /** 只收 mp4 / mov，发送前请转成 H.264 的 MP4。大小上限看 features().videoMaxMb。封面由接入方截。 */
  sendVideo(to: string, file: ImFile, opts: { durationMs: number; width: number; height: number; cover?: ImFile }): Promise<ImMessage> {
    return this.session().sender.video(to, file, opts)
  }

  sendLocation(to: string, lat: number, lng: number, opts: { name?: string; address?: string } = {}): Promise<ImMessage> {
    return this.session().sender.location(to, lat, lng, opts)
  }

  /** data 须为对象（业务卡片放 data.im_card），desc 用于会话预览与离线推送。 */
  sendCustom(to: string, data: Record<string, unknown>, desc: string): Promise<ImMessage> {
    return this.session().sender.custom(to, data, desc)
  }

  /** 重发本人的 failed 消息，沿用原 clientMsgId。 */
  resend(failed: ImMessage): Promise<ImMessage> {
    return this.session().sender.resend(failed)
  }

  /** 图片可用地址，过期会自动续；类型不对为 null。语音、文件、视频同理。 */
  imageUrl(m: ImMessage): Promise<string | null> {
    return this.mediaUrl(m, 'image')
  }

  voiceUrl(m: ImMessage): Promise<string | null> {
    return this.mediaUrl(m, 'voice')
  }

  /** 文件下载地址（强制下载、带原文件名）。 */
  fileUrl(m: ImMessage): Promise<string | null> {
    return this.mediaUrl(m, 'file')
  }

  videoUrl(m: ImMessage): Promise<string | null> {
    return this.mediaUrl(m, 'video')
  }

  videoCoverUrl(m: ImMessage): Promise<string | null> {
    return this.mediaUrl(m, 'video', 'cover_url')
  }

  private async mediaUrl(m: ImMessage, type: string, key?: 'url' | 'cover_url'): Promise<string | null> {
    const url = await this.session().sender.mediaUrl(m, type, key)
    return url && url[0] === '/' ? this.base + url : url
  }

  // ---------------- 内部 ----------------

  private session(): Session {
    if (!this.s) throw new Error('未登录')
    return this.s
  }

  /** 接口调用统一入口：换令牌时 provider 说被踢了，先走 kickedOut 再上抛。 */
  private async run<T>(s: Session, f: () => Promise<T>): Promise<T> {
    try {
      return await f()
    } catch (e) {
      if (isKickedOut(e)) this.kick(s)
      throw e
    }
  }

  private setState(state: ImConnectionState): void {
    if (this.state === state) return
    this.state = state
    this.emitter.emit('connection', state)
  }

  private snapshot(s: Session, forceTotal = false): void {
    if (this.s !== s) return
    this.emit(s, 'conversations', s.store.conversations())
    const total = s.store.totalUnread()
    if (forceTotal || total !== this.unread) {
      this.unread = total
      this.emit(s, 'totalUnread', total)
    }
  }

  private showTyping(s: Session, id: number, from: string, ttlMs: number): void {
    if (this.s !== s) return
    clearTimeout(s.typingTimers.get(id))
    s.typingTimers.set(id, setTimeout(() => this.stopTyping(s, id, from), ttlMs))
    this.emit(s, 'typing', { conversationId: id, from, active: true })
  }

  private stopTyping(s: Session, id: number, from: string): void {
    const t = s.typingTimers.get(id)
    if (t === undefined) return
    clearTimeout(t)
    s.typingTimers.delete(id)
    this.emit(s, 'typing', { conversationId: id, from, active: false })
  }

  private async connect(s: Session): Promise<void> {
    this.setState('connecting')
    try {
      const token = await s.tokens.current()
      if (this.s !== s || s.kicked) return
      this.dial(s, token)
    } catch (e) {
      this.connectFailed(s, e)
    }
  }

  private dial(s: Session, token: string): void {
    s.rt ??= this.realtimeFactory(webSocketUrl(this.base), this.platform, {
      onConnecting: () => this.live(s) && this.setState('connecting'),
      onConnected: () => {
        if (!this.live(s)) return
        s.authRetries = 0
        this.setState('connected')
        void s.sync.reconcile()
      },
      onDisconnected: code => {
        if (!this.live(s)) return
        if (code === CODE_KICKED) this.kick(s)
        // 1：centrifuge 自己认为令牌不可用（本服务端正常不会出现）
        else if (code === CODE_TOKEN_INVALID || code === 1) void this.reauth(s)
        else this.setState('disconnected')
      },
      onPublication: data => this.live(s) && s.sync.handlePush(data),
    })
    s.rtToken = token
    s.rt.connect(token)
  }

  private live(s: Session): boolean {
    return this.s === s && !s.kicked
  }

  private connectFailed(s: Session, e: unknown): void {
    if (!this.live(s)) return
    if (isKickedOut(e)) return this.kick(s)
    console.warn('[guokit-im] 取令牌或连接失败', e)
    this.setState('disconnected')
  }

  private async reauth(s: Session): Promise<void> {
    if (s.authRetries >= MAX_AUTH_RETRIES) {
      // 缓存里还是刚被拒的令牌就丢掉，否则再 login 会一直拿它连
      if (s.rtToken !== null && s.tokens.cached === s.rtToken) s.tokens.clear()
      this.setState('disconnected')
      return
    }
    s.authRetries++
    this.setState('connecting')
    try {
      const token = await s.tokens.refresh(s.rtToken ?? undefined)
      if (this.live(s)) this.dial(s, token)
    } catch (e) {
      this.connectFailed(s, e)
    }
  }

  /** 被封 / 被踢：先断开再发事件。本地数据还能读，等 App 调 logout。 */
  private kick(s: Session): void {
    if (!this.live(s)) return
    s.kicked = true
    s.rt?.close()
    s.rt = null
    this.setState('disconnected')
    this.emit(s, 'kickedOut', undefined)
  }

  private onVisibility(s: Session, visible: boolean): void {
    if (!visible) {
      s.hiddenAt = Date.now()
      return
    }
    const away = s.hiddenAt === null ? 0 : Date.now() - s.hiddenAt
    s.hiddenAt = null
    this.resume(s, this.platform.suspends && away >= AWAY_MS)
  }

  private onNetwork(s: Session, c: NetworkChange): void {
    if (!c.online) s.rt?.network('offline')
    else this.resume(s, c.switched === true)
  }

  /** 回前台 / 恢复网络。force：现有连接不可信，丢掉重连。 */
  private resume(s: Session, force: boolean): void {
    if (!this.live(s)) return
    // centrifuge 已断开时派事件没用，由门面重连；不清换令牌计数，免得每次回前台都打满 provider
    if (this.state === 'disconnected') return void this.connect(s)
    if (!s.rt) return // 正在取令牌
    if (force) s.rt.network('offline')
    s.rt.network('online')
    if (!force && this.state === 'connected') void s.sync.reconcile()
  }
}

const byCreated = (a: ImMessage, b: ImMessage) => a.createdAt - b.createdAt

/** 本地这一页能否直接用：seq 连续，条数够或已到能看到的第一条，翻历史时还要紧接 beforeSeq。 */
function isComplete(l: ImMessage[], limit: number, firstSeq: number, beforeSeq?: number): boolean {
  if (!l.length) return false
  for (let i = 1; i < l.length; i++) if (l[i].seq !== l[i - 1].seq! + 1) return false
  if (beforeSeq && l[l.length - 1].seq !== beforeSeq - 1) return false
  return l.length >= limit || l[0].seq! <= firstSeq
}

function utf8Length(s: string): number {
  let n = 0
  for (const ch of s) {
    const c = ch.codePointAt(0)!
    n += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4
  }
  return n
}
