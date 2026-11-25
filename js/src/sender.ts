import type { ImApi, Raw } from './api.js'
import { ImApiError, isKickedOut } from './errors.js'
import { makeMessage, messageFromServer, patchMessage, type ImMessage, type ImSendProgress } from './models.js'
import { isBlob, type ImFile, type ImPlatform } from './platform/types.js'
import type { Store } from './store.js'
import type { Sync } from './sync.js'

/** 服务端给的附件链接约 24 小时过期，超过这么久就重拉。 */
const URL_MAX_AGE = 20 * 3600_000

/** 要先上传的类型 → 发送时 content 带哪些键。 */
const MEDIA: Record<string, string[]> = {
  image: ['attachment_id', 'ticket', 'width', 'height'],
  voice: ['attachment_id', 'ticket', 'duration'],
  file: ['attachment_id', 'ticket', 'name'],
  video: ['attachment_id', 'ticket', 'duration', 'width', 'height', 'cover_attachment_id', 'cover_ticket'],
}
const DEFAULT_NAME: Record<string, string> = { image: 'image.jpg', voice: 'voice.mp3', file: 'file', video: 'video.mp4' }

export interface SenderHooks {
  onUpdated(m: ImMessage): void
  onSnapshot(): void
  onKickedOut(): void
  onProgress(p: ImSendProgress): void
  /** 会话已作废（登出 / 换号）。 */
  closed(): boolean
}

class LocalFailure extends Error {
  constructor(readonly code: string, message: string) {
    super(message)
  }
}

/** 发送与附件链接续期。send* 在终态完成，发送失败不抛，看 status 与 errorCode；参数错误同步抛。 */
export class Sender {
  /** 附件本体，留到 sent / rejected；failed 时留着给 resend。 */
  private files = new Map<string, ImFile>()
  private covers = new Map<string, ImFile>()

  constructor(
    private api: ImApi, private store: Store, private sync: Sync,
    private platform: ImPlatform, private me: string, private hooks: SenderHooks,
  ) {}

  text(to: string, text: string): Promise<ImMessage> {
    return this.create(to, 'text', { text })
  }

  location(to: string, lat: number, lng: number, o: { name?: string; address?: string }): Promise<ImMessage> {
    const content: Raw = { lat, lng }
    if (o.name) content.name = o.name
    if (o.address) content.address = o.address
    return this.create(to, 'location', content)
  }

  custom(to: string, data: Raw, desc: string): Promise<ImMessage> {
    if (!data || typeof data !== 'object' || Array.isArray(data)) throw new TypeError('data 须为对象')
    return this.create(to, 'custom', { data, desc })
  }

  image(to: string, file: ImFile, o: { width?: number; height?: number }): Promise<ImMessage> {
    const size = o.width !== undefined && o.height !== undefined ? { width: side(o.width), height: side(o.height) } : {}
    return this.create(to, 'image', size, file)
  }

  voice(to: string, file: ImFile, durationMs: number): Promise<ImMessage> {
    return this.create(to, 'voice', { duration: seconds(durationMs, 60, '语音') }, file)
  }

  file(to: string, file: ImFile, name?: string): Promise<ImMessage> {
    this.platform.checkFile(file)
    const n = name || nameOf(file)
    if (!n) throw new TypeError('拿不到文件名，请传 name（要带扩展名）')
    const size = sizeOf(file)
    return this.create(to, 'file', size === null ? { name: n } : { name: n, size }, file)
  }

  video(to: string, file: ImFile, o: { durationMs: number; width: number; height: number; cover?: ImFile }): Promise<ImMessage> {
    if (o.cover) this.platform.checkFile(o.cover)
    const content: Raw = { duration: seconds(o.durationMs, 3600, '视频'), width: side(o.width), height: side(o.height) }
    return this.create(to, 'video', content, file, o.cover)
  }

  /** 沿用原 clientMsgId（服务端幂等）。rejected 不能重发。 */
  resend(failed: ImMessage): Promise<ImMessage> {
    if (failed.status !== 'failed' || failed.from !== this.me) throw new TypeError('只能重发本人的 failed 消息')
    const current = this.store.messageByCid(this.me, failed.clientMsgId) ?? failed
    if (current.status !== 'failed') return Promise.resolve(current) // 已发成功，或正在重发
    return this.start(patchMessage(current, { status: 'sending', errorCode: null, errorMessage: null }))
  }

  /** 附件可用地址：外链原样；上传的链接为空或取得超过 20 小时就重拉这条消息。重拉失败返回旧地址。 */
  async mediaUrl(message: ImMessage, type: string, key: 'url' | 'cover_url' = 'url'): Promise<string | null> {
    if (message.type !== type) return null
    const m = (message.id !== null && this.store.messageById(message.id)) || message
    // 没有封面时服务端给的 cover_attachment_id 是 0，不能当成过期去重拉
    if (key === 'cover_url' && !m.content.cover_attachment_id) return null
    const url: string | null = m.content[key] || null
    if (!m.content.attachment_id || m.conversationId === null || m.seq === null) return url
    if (url && m.urlFetchedAt !== null && Date.now() - m.urlFetchedAt < URL_MAX_AGE) return url
    try {
      const r = await this.api.messages(m.conversationId, { afterSeq: m.seq - 1, limit: 1 })
      this.sync.ingest(m.conversationId, r.items, false)
      const latest = m.id === null ? null : this.store.messageById(m.id)
      if (latest) {
        const fresh: string | null = latest.content[key] || null
        // 地址没变不发事件：接入方常在 messageUpdated 里刷新并再取地址，会循环请求
        if (fresh !== url) this.hooks.onUpdated(latest)
        return fresh
      }
    } catch (e) {
      if (isKickedOut(e)) this.hooks.onKickedOut()
    }
    return url
  }

  // ---------------- 内部 ----------------

  private create(to: string, type: string, content: Raw, file?: ImFile, cover?: ImFile): Promise<ImMessage> {
    if (!to || typeof to !== 'string') throw new TypeError('to 须为非空字符串')
    if (file !== undefined || MEDIA[type]) this.platform.checkFile(file!)
    const clientMsgId = uuid()
    if (file) this.files.set(clientMsgId, file)
    if (cover) this.covers.set(clientMsgId, cover)
    return this.start(makeMessage({
      id: null, clientMsgId, conversationId: this.store.conversationByPeer(to)?.id ?? null, seq: null,
      from: this.me, to, isSelf: true, type, content, status: 'sending', errorCode: null, errorMessage: null,
      createdAt: Date.now(), localPath: file && !isBlob(file) ? file.path : null, urlFetchedAt: null, senderRole: null,
    }))
  }

  private start(local: ImMessage): Promise<ImMessage> {
    this.store.upsertMessage(local)
    this.hooks.onUpdated(local)
    return this.deliver(local)
  }

  private async deliver(local: ImMessage): Promise<ImMessage> {
    let m = local
    try {
      const keys = MEDIA[m.type]
      if (keys && !m.content.attachment_id) {
        // 分两步各自落库：正文失败时，传好的封面不丢
        m = await this.uploadCover(m)
        m = await this.uploadMain(m)
      }
      const content = keys ? pick(m.content, keys) : m.content
      const resp = await this.api.sendMessage(m.to, m.type, content, m.clientMsgId)
      const { message } = this.store.upsertMessage(messageFromServer(resp, this.me, m.to))
      this.forget(m.clientMsgId)
      this.hooks.onUpdated(message)
      if (message.conversationId !== null && !this.store.conversation(message.conversationId)) {
        void this.sync.ensureConversation(message.conversationId)
      }
      this.hooks.onSnapshot()
      return message
    } catch (e) {
      return this.fail(m, e)
    }
  }

  private fail(m: ImMessage, e: unknown): ImMessage {
    let status: 'failed' | 'rejected' = 'failed'
    // 其余异常多为接入方 tokenProvider 自家接口断网，按临时失败
    let code = 'NETWORK'
    if (this.hooks.closed()) code = 'UNKNOWN'
    else if (isKickedOut(e)) {
      code = 'KICKED_OUT'
      this.hooks.onKickedOut()
    } else if (e instanceof ImApiError) {
      code = e.code
      if (code === 'IM_BLOCKED' || code === 'IM_MESSAGE_REJECTED') status = 'rejected'
    } else if (e instanceof LocalFailure) code = e.code
    const errorMessage = String((e as Error)?.message ?? e)
    // 推送可能已先把它合并成 sent，存储不会降级，以存储结果为准
    const { message } = this.store.upsertMessage(patchMessage(m, { status, errorCode: code, errorMessage }))
    if (message.status !== 'failed') this.forget(m.clientMsgId)
    this.hooks.onUpdated(message)
    return message
  }

  /** 服务端不收这张封面就不带封面继续发；网络等其他失败照常失败，重发时再传。 */
  private async uploadCover(m: ImMessage): Promise<ImMessage> {
    const cover = this.covers.get(m.clientMsgId)
    if (!cover) return m
    try {
      const up = await this.api.upload(cover, nameOf(cover) ?? 'cover.jpg', 'image')
      m = this.patchContent(m, { cover_attachment_id: up.attachment_id, cover_ticket: up.ticket, cover_url: up.url })
    } catch (e) {
      if (!(e instanceof ImApiError && e.code === 'VALIDATION')) throw e
    }
    this.covers.delete(m.clientMsgId)
    return m
  }

  /** 取宽高 → 上传；成功后把附件 id、凭证写回本地，重发时不再上传。 */
  private async uploadMain(m: ImMessage): Promise<ImMessage> {
    const { clientMsgId, type } = m
    const file = this.files.get(clientMsgId)
    if (!file) throw new LocalFailure(`${type.toUpperCase()}_MISSING`, '附件已不在内存中，无法重发')
    if (type === 'image' && !m.content.width) {
      const size = await this.platform.imageSize(file).catch(e => {
        throw new LocalFailure('IMAGE_DECODE', `无法识别图片：${e?.message ?? e}`)
      })
      m = this.patchContent(m, { width: Math.round(size.width), height: Math.round(size.height) })
    }
    let active = true // 超时后底层请求可能还在传，不再报它的进度
    let total = 0
    try {
      const up = await this.api.upload(file, m.fileName ?? nameOf(file) ?? DEFAULT_NAME[type], type, (sent, t) => {
        total = t
        if (active) this.hooks.onProgress({ clientMsgId, sent, total: t })
      })
      const patch: Raw = { attachment_id: up.attachment_id, ticket: up.ticket, url: up.url }
      const size = sizeOf(file) ?? total
      if ((type === 'file' || type === 'video') && size) patch.size = size
      return this.patchContent(m, patch)
    } finally {
      active = false
    }
  }

  private patchContent(m: ImMessage, patch: Raw): ImMessage {
    return this.store.upsertMessage(patchMessage(m, { content: { ...m.content, ...patch } })).message
  }

  private forget(cid: string): void {
    this.files.delete(cid)
    this.covers.delete(cid)
  }
}

function pick(o: Raw, keys: string[]): Raw {
  const r: Raw = {}
  for (const k of keys) if (o[k] !== undefined && o[k] !== null) r[k] = o[k]
  return r
}

/** 服务端只收整数秒：四舍五入，不足 1 秒算 1。 */
function seconds(ms: number, max: number, what: string): number {
  const s = Math.round(ms / 1000)
  if (!(ms > 0) || s > max) throw new RangeError(`${what}时长须在 ${max} 秒以内（当前 ${ms} 毫秒）`)
  return Math.max(1, s)
}

function side(v: number): number {
  const n = Math.round(v)
  if (!(n >= 1 && n <= 20000)) throw new RangeError(`宽高须为 1–20000（当前 ${v}）`)
  return n
}

const nameOf = (f: ImFile): string | null => {
  const n = (f as { name?: unknown }).name
  if (typeof n === 'string' && n) return n
  const path = isBlob(f) ? '' : f.path
  return /^(blob|data):/.test(path) ? null : /[^/\\]+\.[^/\\.]+$/.exec(path)?.[0] ?? null
}

const sizeOf = (f: ImFile): number | null => (typeof f.size === 'number' ? f.size : null)

/** 服务端按「发送者 + id」永久幂等、不分大小写，撞了会静默返回旧消息，所以没有 crypto 时混入时间戳。 */
export function uuid(): string {
  const c = (typeof crypto !== 'undefined' ? crypto : null) as Crypto | null
  if (c && typeof c.randomUUID === 'function') return c.randomUUID()
  let hex = Date.now().toString(16).padStart(12, '0').slice(-12)
  while (hex.length < 32) hex += Math.floor(Math.random() * 0x10000).toString(16).padStart(4, '0')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-8${hex.slice(17, 20)}-${hex.slice(20, 32)}`
}
