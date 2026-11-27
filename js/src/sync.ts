import type { ImApi, Raw } from './api.js'
import { isKickedOut } from './errors.js'
import { messageFromServer, previewOf, type ImMessage, type ImMessageStatus } from './models.js'
import type { Store } from './store.js'
import { parseCst } from './time.js'

const PULL_LIMIT = 100

export interface SyncHooks {
  onNewMessage(m: ImMessage): void
  onMessageUpdated(m: ImMessage): void
  /** 会话或未读有变化。 */
  onChanged(): void
  /** 队列任务失败，只关心踢下线。 */
  onError(e: unknown): void
  onTyping(conversationId: number, from: string, ttlMs: number): void
  /** friend_request / friend_changed / friend_groups_changed，由门面交给好友缓存。 */
  onFriendPush(ev: Raw): void
}

const FRIEND_EVENTS = ['friend_request', 'friend_changed', 'friend_groups_changed']

/**
 * 对账、推送处理、补拉。对账与推送进同一个串行队列，避免并发补拉交错；单个任务失败不影响后续。
 * 一次登录一个实例，登出时 close，队列里剩下的直接跳过。
 */
export class Sync {
  private closed = false
  private tail: Promise<void> = Promise.resolve()
  private pendingReconcile: Promise<void> | null = null
  /** 本次登录已完整翻过一遍会话列表。没翻完过就不能「一页没推进就停」，否则后面的页再也翻不到。 */
  private listed = false
  /** 本次登录删除过的会话 → 当时的 clearSeq。挡住删除前发出、删除后才返回的拉消息结果。 */
  private deletedSeq = new Map<number, number>()

  constructor(private api: ImApi, private store: Store, private me: string, private hooks: SyncHooks) {}

  /** 队列排空时完成（测试用）。 */
  get idle(): Promise<void> {
    return this.tail
  }

  close(): void {
    this.closed = true
  }

  private enqueue(job: () => Promise<void> | void): Promise<void> {
    return (this.tail = this.tail.then(async () => {
      if (this.closed) return
      try {
        await job()
      } catch (e) {
        if (!this.closed) this.hooks.onError(e)
      }
    }))
  }

  /** 队列里已有一次还没开始的对账时复用它。 */
  reconcile(): Promise<void> {
    return (this.pendingReconcile ??= this.enqueue(() => {
      this.pendingReconcile = null
      return this.doReconcile()
    }))
  }

  handlePush(ev: Raw): void {
    if (this.closed || !ev || typeof ev !== 'object') return
    if (ev.event === 'typing') {
      // 不进队列：对账在跑时也要立刻显示
      this.hooks.onTyping(ev.conversation_id, ev.from, (ev.expires_in ?? 6) * 1000)
      return
    }
    if (FRIEND_EVENTS.includes(ev.event)) {
      this.hooks.onFriendPush(ev) // 与会话无关，不排进会话队列
      return
    }
    void this.enqueue(() => this.push(ev))
  }

  applyRecall(message: Raw): Promise<void> {
    return this.enqueue(() => {
      this.ingest(message.conversation_id, [message], false)
      this.hooks.onChanged()
    })
  }

  applySettings(settings: Raw): Promise<void> {
    return this.enqueue(() => {
      this.doSettings(settings)
      this.hooks.onChanged()
    })
  }

  /** 本设备发出、本地还没有这个会话时调：拉一次列表把会话带出来。 */
  ensureConversation(id: number): Promise<void> {
    return this.enqueue(async () => {
      if (await this.loadConversation(id)) this.hooks.onChanged()
    })
  }

  private async doReconcile(): Promise<void> {
    // 1. 翻会话列表；翻完过一遍之后，一整页的 maxSeq 都不超过本地记录就停
    let cursor: string | null = null
    do {
      const page: Awaited<ReturnType<ImApi['conversations']>> = await this.api.conversations(cursor, 50)
      const advanced = page.items.some(c => c.maxSeq > (this.store.conversation(c.id)?.maxSeq ?? -1))
      this.store.upsertConversations(page.items)
      if (this.listed && !advanced) break
      cursor = page.nextCursor
    } while (cursor)
    this.listed = true
    this.hooks.onChanged() // 冷启动没有本地缓存，列表先出来，不等后面的增量

    // 2. 离线期间别的设备改的会话设置。「已删除」只能从这里知道。旧服务端没有接口，失败不影响后面
    await this.tolerate(() => this.pullChanges())
    // 3. 离线期间的撤回。撤回不产生新 seq，补拉拿不到
    await this.tolerate(() => this.pullRecalls())
    // 4. 只补拉拉过消息且落后的会话；从没拉过的等打开时再拉
    for (const c of this.store.conversations()) {
      const synced = this.store.syncedSeq(c.id)
      if (synced > 0 && synced < c.maxSeq) await this.pullAfter(c.id, synced, true)
    }
    this.hooks.onChanged()
  }

  private async pullChanges(): Promise<void> {
    for (;;) {
      const r = await this.api.conversationChanges(this.store.changesCursor, 200)
      r.items.forEach(s => this.doSettings(s))
      if (!r.nextCursor) return
      this.store.changesCursor = r.nextCursor
      if (!r.hasMore) return
    }
  }

  /** 只更新本地已有的消息与会话预览，不插入：第一次会拿到全部历史撤回。 */
  private async pullRecalls(): Promise<void> {
    for (;;) {
      const r = await this.api.recalls(this.store.recallsCursor, 200)
      for (const it of r.items) {
        const id: number = it.conversation_id
        if (this.store.messageById(it.message_id)) {
          this.ingest(id, [it.message], false)
          continue
        }
        const last = this.store.conversation(id)?.lastMessage
        if (last && last.type !== 'recalled' && last.seq === it.seq) {
          const m = messageFromServer(it.message, this.me)
          this.store.patchConversation(id, { lastMessage: { ...last, type: m.type, preview: previewOf(m) } })
        }
      }
      if (!r.nextCursor) return
      this.store.recallsCursor = r.nextCursor
      if (!r.hasMore) return
    }
  }

  /** 用一份会话设置（写接口返回、conversation_changed、增量）覆盖本地，可重复应用。形状与会话列表项不同。 */
  private doSettings(s: Raw): void {
    const id: number = s.conversation_id
    const clearSeq: number = s.clear_seq
    const local = this.store.conversation(id)
    // 本地已有更新的消息，说明会话在删除后又因新消息出现、这份设置是旧的，只清空、不删会话
    if (s.visible === false && (!local || local.maxSeq <= clearSeq)) {
      this.deletedSeq.set(id, Math.max(this.deletedSeq.get(id) ?? 0, clearSeq))
      this.store.deleteConversation(id)
      return
    }
    if (!local) return // 由会话列表带出来
    this.store.clearMessages(id, clearSeq)
    this.store.patchConversation(id, { pinnedAt: s.pinned_at ? parseCst(s.pinned_at) : null, muted: s.muted })
  }

  private async push(ev: Raw): Promise<void> {
    const id: number = ev.conversation_id
    switch (ev.event) {
      case 'message': {
        const known = this.store.conversation(id) !== null || (await this.loadConversation(id))
        const synced = this.store.syncedSeq(id)
        // 跳号先补中间段。失败也照样入库这条，断档留给下次对账
        if (synced > 0 && ev.seq > synced + 1) await this.tolerate(() => this.pullAfter(id, synced, true))
        this.ingest(id, [ev.message], true)
        if (!known) void this.reconcile()
        break
      }
      case 'read':
        this.store.setReadSeq(id, ev.read_seq)
        break
      case 'read_all':
        this.store.markAllRead()
        break
      case 'message_recalled':
        // 本地没有这个会话（从没聊过或已删除）就忽略，别让它复活
        if (!this.store.conversation(id)) return
        this.ingest(id, [ev.message], false)
        break
      case 'peer_read':
        this.store.setPeerReadSeq(id, ev.peer_read_seq)
        break
      case 'conversation_changed':
        this.doSettings(ev.conversation)
        break
      default:
        return
    }
    this.hooks.onChanged()
  }

  /** 列表首页是「全部置顶 + 最新一页非置顶」，刚有消息的会话必在其中。拉不到就不建占位，等下次对账。 */
  private async loadConversation(id: number): Promise<boolean> {
    if (!this.store.conversation(id)) {
      await this.tolerate(async () => this.store.upsertConversations((await this.api.conversations()).items))
    }
    return this.store.conversation(id) !== null
  }

  /** 吞掉除踢下线以外的错误。 */
  private async tolerate(f: () => Promise<void>): Promise<void> {
    try {
      await f()
    } catch (e) {
      if (isKickedOut(e)) throw e
    }
  }

  /** 按 after_seq 补拉到追平。不进队列，门面也直接调。 */
  async pullAfter(id: number, afterSeq: number, notify: boolean): Promise<void> {
    for (let cursor = afterSeq; ; ) {
      const r = await this.api.messages(id, { afterSeq: cursor, limit: PULL_LIMIT })
      if (!r.items.length) return
      this.ingest(id, r.items, notify)
      if (!r.hasMore) return
      cursor = r.items[r.items.length - 1].seq
    }
  }

  /**
   * 服务端消息入库。notify 为 true 时新插入的发 newMessage；不论 notify，本设备未确认的被合并成 sent、
   * 本地消息变成已撤回时发 messageUpdated。离线期间「发了又撤」的不弹新消息，改发 messageUpdated。
   */
  ingest(id: number, raw: Raw[], notify: boolean): void {
    const peerId = this.store.conversation(id)?.peer?.userId
    const floor = this.deletedSeq.get(id) ?? 0
    for (const j of raw) {
      if (this.closed) return
      if (j.seq <= floor) continue
      const m = messageFromServer(j, this.me, peerId)
      const prev = (m.id !== null && this.store.messageById(m.id)) || this.store.messageByCid(m.from, m.clientMsgId)
      const prevStatus: ImMessageStatus | null = prev ? prev.status : null
      const r = this.store.upsertMessage(m)
      if (m.isRecalled) {
        // 增量与推送会重复给，只在真的变成撤回时发；本地没有的（含已清空的）不算变化
        const changed = r.inserted ? notify : prev !== null && !prev.isRecalled
        if (changed && r.message.isRecalled) this.hooks.onMessageUpdated(r.message)
      } else if (r.inserted) {
        if (notify) this.hooks.onNewMessage(r.message)
      } else if (m.isSelf && prevStatus && prevStatus !== 'sent') {
        this.hooks.onMessageUpdated(r.message)
      }
    }
  }
}
