import { patchConversation, patchMessage, previewOf, type ConversationBase, type ImConversation, type ImMessage, type ImMessagePreview } from './models.js'

/** 已确认：服务端接收过，有会话 id 与 seq。未确认：本设备发出、seq 为空的 sending / failed / rejected。 */
const isConfirmed = (m: ImMessage): m is ImMessage & { conversationId: number; seq: number } =>
  m.conversationId !== null && m.seq !== null

const cidKey = (from: string, cid: string) => `${from}\u0000${cid}`

export interface UpsertResult {
  message: ImMessage
  /** 本地原来没有（按 id、按「发送者 + clientMsgId」都没匹配上）。 */
  inserted: boolean
}

/**
 * 内存存储与合并规则，一次登录一个实例。全部同步，调用之间不会被别的流程打断。
 * 合并的两条铁律：撤回不可逆；已确认的不会被本地版本降级。
 */
export class Store {
  private convs = new Map<number, ImConversation>()
  private synced = new Map<number, number>()
  private msgs = new Map<number, ImMessage>()
  private byId = new Map<number, number>()
  private byCid = new Map<string, number>()
  private nextLocalId = 1

  changesCursor: string | null = null
  recallsCursor: string | null = null

  // ---------------- 会话 ----------------

  /** 写入服务端会话列表的一页：seq 类取大，其余取服务端；清空水位变大时把旧消息一起清掉。 */
  upsertConversations(list: ImConversation[]): void {
    for (const c of list) {
      this.convs.set(c.id, mergeConversation(this.convs.get(c.id), c))
      if (c.clearSeq > 0) this.purge(c.id, c.clearSeq)
      this.startSynced(c.id)
    }
  }

  patchConversation(id: number, patch: Partial<ConversationBase>): void {
    const c = this.convs.get(id)
    if (c) this.convs.set(id, patchConversation(c, patch))
  }

  conversation(id: number): ImConversation | null {
    return this.convs.get(id) ?? null
  }

  conversationByPeer(peerId: string): ImConversation | null {
    for (const c of this.convs.values()) if (c.peer && c.peer.userId === peerId) return c
    return null
  }

  /** 按对方回写会话的好友备注，返回是否有变化。 */
  setPeerRemark(userId: string, remark: string): boolean {
    let changed = false
    for (const c of this.convs.values()) {
      if (c.peer && c.peer.userId === userId && c.peer.remark !== remark) {
        this.convs.set(c.id, patchConversation(c, { peer: { ...c.peer, remark } }))
        changed = true
      }
    }
    return changed
  }

  /** 置顶在前（按置顶时间倒序），其余按最后消息时间倒序，再按 id 倒序。 */
  conversations(): ImConversation[] {
    return [...this.convs.values()].sort((a, b) =>
      (b.pinnedAt ?? -1) - (a.pinnedAt ?? -1) || b.lastMsgAt - a.lastMsgAt || b.id - a.id)
  }

  /** 只进不退。 */
  setReadSeq(id: number, readSeq: number): void {
    const c = this.convs.get(id)
    if (c && readSeq > c.readSeq) this.patchConversation(id, { readSeq })
  }

  setPeerReadSeq(id: number, peerReadSeq: number): void {
    const c = this.convs.get(id)
    if (c && peerReadSeq > (c.peerReadSeq ?? -1)) this.patchConversation(id, { peerReadSeq })
  }

  markAllRead(): void {
    for (const c of this.convs.values()) this.setReadSeq(c.id, c.maxSeq)
  }

  totalUnread(): number {
    let n = 0
    for (const c of this.convs.values()) if (!c.muted) n += c.unread
    return n
  }

  /** 清空到 clearSeq：删掉范围内的消息，各水位不低于它，范围内的预览置 null。未确认消息不动。 */
  clearMessages(id: number, clearSeq: number): void {
    const c = this.convs.get(id)
    if (!c || clearSeq <= c.clearSeq) return
    const last = c.lastMessage
    this.patchConversation(id, {
      clearSeq,
      maxSeq: Math.max(c.maxSeq, clearSeq),
      readSeq: Math.max(c.readSeq, clearSeq),
      lastMessage: last && last.seq > clearSeq ? last : null,
    })
    this.purge(id, clearSeq)
  }

  private purge(id: number, clearSeq: number): void {
    this.removeMessages(m => m.conversationId === id && m.seq !== null && m.seq <= clearSeq)
    const synced = this.syncedSeq(id)
    if (synced > 0 && synced < clearSeq) this.setSyncedSeq(id, clearSeq)
  }

  /** 删除会话行与全部消息，含发给该会话对方的未确认消息。消息不删的话，会话重新出现时旧消息会跟着回来。 */
  deleteConversation(id: number): void {
    const peer = this.convs.get(id)?.peer?.userId
    this.convs.delete(id)
    this.synced.delete(id)
    this.removeMessages(m => m.conversationId === id || (peer !== undefined && m.seq === null && m.isSelf && m.to === peer))
  }

  /** 本地已连续持有到的 seq；0 表示从没拉过这个会话的消息。 */
  syncedSeq(id: number): number {
    return this.synced.get(id) ?? 0
  }

  /** 设置后自动沿本地已有的连续消息往后推进。 */
  setSyncedSeq(id: number, seq: number): void {
    if (!this.convs.has(id)) return
    const have = new Set<number>()
    for (const m of this.msgs.values()) if (m.conversationId === id && m.seq !== null && m.seq > seq) have.add(m.seq)
    let s = seq
    while (have.has(s + 1)) s++
    this.synced.set(id, s)
  }

  /**
   * 还没有起点、但已持有第一条可见消息（新开的会话、清空后来的第一条）：等于完整持有，设起点。
   * 否则聊天页开着、没调过 messages() 的新会话，断线期间的消息不会补拉。
   */
  private startSynced(id: number): void {
    const c = this.convs.get(id)
    if (!c || this.syncedSeq(id) > 0) return
    const first = c.clearSeq + 1
    for (const m of this.msgs.values()) if (m.conversationId === id && m.seq === first) return this.setSyncedSeq(id, first)
  }

  // ---------------- 消息 ----------------

  /** 先按 id、再按「发送者 + clientMsgId」匹配，都没有才插入。清空范围内的不入库，已有的本地版本一并删掉。 */
  upsertMessage(message: ImMessage): UpsertResult {
    let localId = message.id === null ? undefined : this.byId.get(message.id)
    if (localId === undefined) localId = this.byCid.get(cidKey(message.from, message.clientMsgId))
    const inserted = localId === undefined
    const merged = inserted ? message : mergeMessage(this.msgs.get(localId!)!, message)
    if (isConfirmed(merged) && merged.seq <= (this.convs.get(merged.conversationId)?.clearSeq ?? 0)) {
      this.removeMessages(m => m.from === merged.from && m.clientMsgId === merged.clientMsgId)
      return { message: merged, inserted: false }
    }
    if (localId === undefined) localId = this.nextLocalId++
    this.msgs.set(localId, merged)
    this.byCid.set(cidKey(merged.from, merged.clientMsgId), localId)
    if (merged.id !== null) this.byId.set(merged.id, localId)

    if (isConfirmed(merged)) {
      const id = merged.conversationId
      const conv = this.convs.get(id)
      if (conv) this.convs.set(id, bumpConversation(conv, merged, merged.seq))
      const synced = this.syncedSeq(id)
      if (synced > 0 && merged.seq === synced + 1) this.setSyncedSeq(id, synced)
      this.startSynced(id)
    }
    return { message: merged, inserted }
  }

  messageById(id: number): ImMessage | null {
    const l = this.byId.get(id)
    return l === undefined ? null : this.msgs.get(l)!
  }

  messageByCid(from: string, cid: string): ImMessage | null {
    const l = this.byCid.get(cidKey(from, cid))
    return l === undefined ? null : this.msgs.get(l)!
  }

  /** 已确认消息：`seq < beforeSeq` 的最近 limit 条，按 seq 升序。 */
  messages(id: number, limit: number, beforeSeq?: number): ImMessage[] {
    const list = [...this.msgs.values()]
      .filter(m => m.conversationId === id && m.seq !== null && (beforeSeq === undefined || m.seq < beforeSeq))
      .sort((a, b) => a.seq! - b.seq!)
    return list.slice(Math.max(0, list.length - limit))
  }

  /** 发给 peerId 的未确认消息，按插入顺序。首条发成功前还没有会话 id，所以按对方查。 */
  unconfirmed(peerId: string): ImMessage[] {
    return [...this.msgs.entries()]
      .sort((a, b) => a[0] - b[0])
      .map(e => e[1])
      .filter(m => m.seq === null && m.isSelf && m.to === peerId)
  }

  private removeMessages(test: (m: ImMessage) => boolean): void {
    for (const [l, m] of [...this.msgs]) {
      if (!test(m)) continue
      this.msgs.delete(l)
      if (m.id !== null) this.byId.delete(m.id)
      this.byCid.delete(cidKey(m.from, m.clientMsgId))
    }
  }
}

// ---------------- 合并规则 ----------------

function mergeMessage(existing: ImMessage, incoming: ImMessage): ImMessage {
  // 推送先到、HTTP 后超时也不会把它标成 failed
  if (existing.status === 'sent' && incoming.id === null) return existing
  const to = incoming.to || existing.to
  // 在途的翻历史、迟到的发送响应都会带旧版本来
  if (existing.isRecalled && !incoming.isRecalled) return patchMessage(existing, { to: existing.to || to })
  const recalled = incoming.isRecalled
  return patchMessage(incoming, {
    to,
    localPath: recalled ? null : incoming.localPath ?? existing.localPath,
    urlFetchedAt: recalled ? null : incoming.urlFetchedAt ?? existing.urlFetchedAt,
    senderRole: incoming.senderRole ?? existing.senderRole,
  })
}

function mergeConversation(local: ImConversation | undefined, incoming: ImConversation): ImConversation {
  if (!local) return incoming
  const newer = incoming.maxSeq >= local.maxSeq
  const clearSeq = Math.max(local.clearSeq, incoming.clearSeq)
  let last = newer ? incoming.lastMessage ?? local.lastMessage : local.lastMessage
  const mine = local.lastMessage
  // 撤回不可逆：在途的旧列表不能把原文预览写回来
  if (mine && mine.type === 'recalled' && last && last.seq === mine.seq) last = mine
  return patchConversation(incoming, {
    maxSeq: Math.max(local.maxSeq, incoming.maxSeq),
    readSeq: Math.max(local.readSeq, incoming.readSeq),
    clearSeq,
    lastMessage: last && last.seq > clearSeq ? last : null,
    lastMsgAt: newer ? incoming.lastMsgAt : local.lastMsgAt,
    peerReadSeq: incoming.peerReadSeq === null ? null : Math.max(incoming.peerReadSeq, local.peerReadSeq ?? 0),
  })
}

/** 已确认消息对会话的影响：推进 maxSeq 与预览，撤回最后一条时换预览，本人发的推进已读。 */
function bumpConversation(c: ImConversation, m: ImMessage, seq: number): ImConversation {
  const preview: ImMessagePreview = { seq, from: m.from, type: m.type, preview: previewOf(m), createdAt: m.createdAt }
  const patch: Partial<ConversationBase> = {}
  if (seq > c.maxSeq) Object.assign(patch, { maxSeq: seq, lastMessage: preview, lastMsgAt: m.createdAt })
  else if (m.isRecalled && c.lastMessage?.seq === seq && c.lastMessage.type !== 'recalled') patch.lastMessage = preview
  if (m.isSelf && seq > c.readSeq) patch.readSeq = seq
  return patchConversation(c, patch)
}
