import { ClosedError, ImApiError } from './errors.js'
import {
  conversationFromServer, csStateFromServer, featuresFromServer, friendFromServer, friendRequestFromServer,
  type ImAddFriendResult, type ImBlockItem, type ImConversation, type ImCsState, type ImFeatures, type ImFriend,
  type ImFriendGroup, type ImFriendRequest, type ImReportResult,
} from './models.js'
import type { HttpRequest, HttpResult, ImFile, ImPlatform } from './platform/types.js'
import { parseCst } from './time.js'
import type { TokenManager } from './token.js'

const IM = '/api/im/v1'
const CS = '/api/imcs/v1'

const TIMEOUT = 15_000
/** 图片、语音。 */
const UPLOAD_TIMEOUT = 60_000
/** 文件、视频。 */
const MEDIA_TIMEOUT = 300_000

export type Raw = Record<string, any>
export interface CursorPage {
  items: Raw[]
  nextCursor: string
  hasMore: boolean
}
type Query = Record<string, string | number | null | undefined>

/** 客户端 HTTP 接口：拼前缀、带令牌、解析响应包、401 换令牌重试一次。消息类返回服务端原始对象。 */
export class ImApi {
  private closed = false

  constructor(private base: string, private tokens: TokenManager, private platform: ImPlatform) {}

  /** 登出后调：在途请求的结果作废，不再换令牌重试（否则会拿新账号的令牌重发旧账号的请求）。 */
  close(): void {
    this.closed = true
  }

  async features(): Promise<ImFeatures> {
    return featuresFromServer(await this.json('GET', '/me'))
  }

  sendMessage(to: string, type: string, content: Raw, clientMsgId: string): Promise<Raw> {
    return this.json('POST', '/messages', { body: { to, type, content, client_msg_id: clientMsgId } })
  }

  recall(messageId: number): Promise<Raw> {
    return this.json('POST', `/messages/${messageId}/recall`)
  }

  typing(conversationId: number): Promise<unknown> {
    return this.json('POST', `/conversations/${conversationId}/typing`)
  }

  async conversations(cursor?: string | null, limit?: number): Promise<{ items: ImConversation[]; nextCursor: string | null }> {
    const d = await this.json('GET', '/conversations', { query: { cursor, limit } })
    return { items: d.items.map(conversationFromServer), nextCursor: d.next_cursor || null }
  }

  /** afterSeq 补拉、beforeSeq 翻历史、都不传为最新一页；按 seq 升序。 */
  async messages(id: number, q: { afterSeq?: number; beforeSeq?: number; limit?: number }): Promise<{ items: Raw[]; hasMore: boolean }> {
    const d = await this.json('GET', `/conversations/${id}/messages`, {
      query: { after_seq: q.afterSeq, before_seq: q.beforeSeq, limit: q.limit },
    })
    return { items: d.items, hasMore: d.has_more }
  }

  recalls(cursor: string | null, limit: number): Promise<CursorPage> {
    return this.page('/recalls', cursor, limit)
  }

  conversationChanges(cursor: string | null, limit: number): Promise<CursorPage> {
    return this.page('/conversations/changes', cursor, limit)
  }

  async markRead(id: number, seq: number): Promise<number> {
    return (await this.json('POST', `/conversations/${id}/read`, { body: { seq } })).read_seq
  }

  markAllRead(): Promise<unknown> {
    return this.json('POST', '/conversations/read-all')
  }

  setSettings(id: number, body: { pinned?: boolean; muted?: boolean }): Promise<Raw> {
    return this.json('PUT', `/conversations/${id}/settings`, { body })
  }

  clearConversation(id: number): Promise<Raw> {
    return this.json('POST', `/conversations/${id}/clear`)
  }

  deleteConversation(id: number): Promise<Raw> {
    return this.json('DELETE', `/conversations/${id}`)
  }

  block(userId: string): Promise<unknown> {
    return this.json('PUT', `/blocks/${encodeURIComponent(userId)}`)
  }

  unblock(userId: string): Promise<unknown> {
    return this.json('DELETE', `/blocks/${encodeURIComponent(userId)}`)
  }

  async blocks(offset?: number, limit?: number): Promise<{ items: ImBlockItem[]; hasMore: boolean }> {
    const d = await this.json('GET', '/blocks', { query: { offset, limit } })
    return {
      items: d.items.map((e: Raw) => ({ userId: e.user_id, createdAt: parseCst(e.created_at) })),
      hasMore: d.has_more,
    }
  }

  async report(target: string, reason: string, detail?: string, messageIds?: number[], block?: boolean): Promise<ImReportResult> {
    const d = await this.json('POST', '/reports', { body: { target, reason, detail, message_ids: messageIds, block } })
    return { reportId: d.report_id, duplicated: d.duplicated }
  }

  async friends(cursor?: string | null, limit?: number): Promise<{ items: ImFriend[]; nextCursor: string | null }> {
    const d = await this.json('GET', '/friends', { query: { cursor, limit } })
    return { items: d.items.map(friendFromServer), nextCursor: d.next_cursor || null }
  }

  async addFriend(target: string, message?: string): Promise<ImAddFriendResult> {
    const d = await this.json('POST', '/friends', { body: { target, message } })
    return { status: d.status, requestId: d.request_id ?? null }
  }

  deleteFriend(target: string): Promise<unknown> {
    return this.json('DELETE', `/friends/${encodeURIComponent(target)}`)
  }

  async setFriend(target: string, body: { remark?: string; group_ids?: number[] }): Promise<ImFriend> {
    return friendFromServer(await this.json('PUT', `/friends/${encodeURIComponent(target)}`, { body }))
  }

  async friendRequests(box: 'in' | 'out', cursor?: string | null, limit?: number): Promise<{ items: ImFriendRequest[]; nextCursor: string | null }> {
    const d = await this.json('GET', '/friend-requests', { query: { box, cursor, limit } })
    return { items: d.items.map(friendRequestFromServer), nextCursor: d.next_cursor || null }
  }

  async acceptFriend(requestId: number): Promise<ImFriend> {
    return friendFromServer(await this.json('POST', `/friend-requests/${requestId}/accept`))
  }

  rejectFriend(requestId: number): Promise<unknown> {
    return this.json('POST', `/friend-requests/${requestId}/reject`)
  }

  async friendGroups(): Promise<ImFriendGroup[]> {
    return (await this.json('GET', '/friend-groups')).items.map(groupFromServer)
  }

  async createFriendGroup(name: string): Promise<ImFriendGroup> {
    return groupFromServer(await this.json('POST', '/friend-groups', { body: { name } }))
  }

  async updateFriendGroup(id: number, body: { name?: string; sort?: number }): Promise<ImFriendGroup> {
    return groupFromServer(await this.json('PUT', `/friend-groups/${id}`, { body }))
  }

  deleteFriendGroup(id: number): Promise<unknown> {
    return this.json('DELETE', `/friend-groups/${id}`)
  }

  setFriendAddPolicy(policy: number): Promise<unknown> {
    return this.json('PUT', '/me/friend-settings', { body: { add_policy: policy } })
  }

  async csState(serviceId?: string): Promise<ImCsState> {
    return csStateFromServer(await this.json('GET', '/state', { prefix: CS, query: { service_id: serviceId || null } }))
  }

  async csHandoff(): Promise<ImCsState> {
    return csStateFromServer(await this.json('POST', '/handoff', { prefix: CS }))
  }

  csRate(sessionId: number, rating: number, comment: string): Promise<unknown> {
    return this.json('POST', `/sessions/${sessionId}/rating`, { prefix: CS, body: comment ? { rating, comment } : { rating } })
  }

  async csLeave(name: string, phone: string, email: string): Promise<string> {
    const body: Raw = {}
    if (name) body.contact_name = name
    if (phone) body.contact_phone = phone
    if (email) body.contact_email = email
    return (await this.json('POST', '/leave', { prefix: CS, body })).ticket_no
  }

  upload(file: ImFile, filename: string, kind: string, onProgress?: (sent: number, total: number) => void): Promise<Raw> {
    return this.send(token => this.platform.upload({
      url: `${this.base}${IM}/upload`,
      headers: { Authorization: `Bearer ${token}` },
      fields: { kind },
      file,
      filename,
      timeoutMs: kind === 'file' || kind === 'video' ? MEDIA_TIMEOUT : UPLOAD_TIMEOUT,
      onProgress,
    }))
  }

  private async page(path: string, cursor: string | null, limit: number): Promise<CursorPage> {
    const d = await this.json('GET', path, { query: { cursor, limit } })
    return { items: d.items, nextCursor: d.next_cursor, hasMore: d.has_more }
  }

  private json(method: HttpRequest['method'], path: string, o: { prefix?: string; query?: Query; body?: Raw } = {}): Promise<Raw> {
    const url = `${this.base}${o.prefix ?? IM}${path}${queryString(o.query)}`
    const body = o.body && JSON.stringify(o.body)
    return this.send(token => {
      // 没有请求体也写 Content-Type：uni-app App 端的 POST 不写会变成表单
      const headers: Record<string, string> = { Authorization: `Bearer ${token}` }
      if (method !== 'GET') headers['Content-Type'] = 'application/json'
      return this.platform.request({ method, url, headers, body, timeoutMs: TIMEOUT })
    })
  }

  private async send(once: (token: string) => Promise<HttpResult>): Promise<Raw> {
    const token = await this.token(() => this.tokens.current())
    try {
      return this.parse(await once(token))
    } catch (e) {
      if (!(e instanceof ImApiError && e.httpStatus === 401 && e.isTokenInvalid)) throw this.closed ? new ClosedError() : e
    }
    const next = await this.token(() => this.tokens.refresh(token))
    return this.parse(await once(next))
  }

  private async token(get: () => Promise<string>): Promise<string> {
    if (this.closed) throw new ClosedError()
    const t = await get()
    if (this.closed) throw new ClosedError()
    return t
  }

  private parse(res: HttpResult): Raw {
    if (this.closed) throw new ClosedError()
    let d: any
    try {
      d = JSON.parse(res.text)
    } catch {
      // 落到下面按坏响应处理
    }
    if (!d || typeof d !== 'object' || !('code' in d)) {
      throw new ImApiError('BAD_RESPONSE', `响应不是合法的响应包（HTTP ${res.status}）`, res.status)
    }
    // 成功时 code 是数字 0，失败时是字符串
    if (d.code === 0) return d.data ?? {}
    throw new ImApiError(String(d.code), d.message ?? '', res.status)
  }
}

function groupFromServer(j: Raw): ImFriendGroup {
  return { id: j.id, name: j.name, sort: j.sort ?? 0 }
}

/** 小程序没有 URLSearchParams。 */
function queryString(q: Query = {}): string {
  const parts = Object.keys(q)
    .filter(k => q[k] !== null && q[k] !== undefined && q[k] !== '')
    .map(k => `${k}=${encodeURIComponent(String(q[k]))}`)
  return parts.length ? `?${parts.join('&')}` : ''
}
