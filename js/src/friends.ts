import type { ImApi, Raw } from './api.js'
import { isKickedOut } from './errors.js'
import { friendFromServer, type ImFriend } from './models.js'
import type { Store } from './store.js'

/** 好友对账每页条数：3000 人上限，最多 6 个请求。 */
const PAGE = 500

export interface FriendHooks {
  /** 好友快照变了（已按 userId 升序）。 */
  onFriends(list: ImFriend[]): void
  /** 会话的 peer.remark 被回写了。 */
  onConversations(): void
  onError(e: unknown): void
}

/**
 * 好友缓存，只放内存：离线冷启动为空，连上后补齐。
 * 懒加载：本次登录调用过 friends() 之后，才在连上时全量重拉；对账单独排队、失败不影响会话（旧服务端没有 /friends）。
 */
export class FriendBook {
  private map = new Map<string, ImFriend>()
  /** 本次登录调用过 friends()。 */
  used = false
  private closed = false
  private tail: Promise<void> = Promise.resolve()
  private pending: Promise<void> | null = null

  constructor(private api: ImApi, private store: Store, private hooks: FriendHooks) {}

  close(): void {
    this.closed = true
  }

  /** 队列排空时完成（测试用）。 */
  get idle(): Promise<void> {
    return this.tail
  }

  snapshot(): ImFriend[] {
    return [...this.map.values()].sort((a, b) => (a.userId < b.userId ? -1 : a.userId > b.userId ? 1 : 0))
  }

  get(userId: string): ImFriend | null {
    return this.map.get(userId) ?? null
  }

  /** 全量重拉并整份覆盖；队列里已有一次还没开始的就复用。 */
  reconcile(): Promise<void> {
    return (this.pending ??= this.enqueue(async () => {
      this.pending = null
      const next = new Map<string, ImFriend>()
      let cursor: string | null = null
      do {
        const page: Awaited<ReturnType<ImApi['friends']>> = await this.api.friends(cursor, PAGE)
        page.items.forEach(f => next.set(f.userId, f))
        cursor = page.nextCursor
      } while (cursor)
      if (this.closed) return
      const removed = [...this.map.keys()].filter(id => !next.has(id))
      this.map = next
      let convChanged = false
      for (const id of removed) convChanged = this.store.setPeerRemark(id, '') || convChanged
      for (const f of next.values()) convChanged = this.store.setPeerRemark(f.userId, f.remark) || convChanged
      this.hooks.onFriends(this.snapshot())
      if (convChanged) this.hooks.onConversations()
    }))
  }

  /** friend_changed 推送，或本设备写接口的结果。进同一队列：落在对账翻页期间的不会被对账结果盖掉。 */
  apply(action: string, raw: Raw | ImFriend): Promise<void> {
    const f = 'user_id' in raw ? friendFromServer(raw) : (raw as ImFriend)
    return this.enqueue(async () => this.applyNow(action, f))
  }

  private applyNow(action: string, f: ImFriend): void {
    if (!f.userId) return
    let remark = f.remark
    if (action === 'removed') {
      this.map.delete(f.userId)
      remark = ''
    } else {
      this.map.set(f.userId, f)
    }
    this.hooks.onFriends(this.snapshot())
    if (this.store.setPeerRemark(f.userId, remark)) this.hooks.onConversations()
  }

  private enqueue(job: () => Promise<void>): Promise<void> {
    return (this.tail = this.tail.then(async () => {
      if (this.closed) return
      try {
        await job()
      } catch (e) {
        if (!this.closed && isKickedOut(e)) this.hooks.onError(e)
      }
    }))
  }
}
