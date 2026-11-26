/**
 * 对外数据都是不带方法的普通对象：时间是毫秒时间戳，没有值的字段是 null（不是 undefined），
 * 派生字段直接算好。小程序 setData 传不了方法、Date 与 undefined，Vue / React 也好展开。
 * 每次变化给新对象，不原地改。
 */
import { parseCst } from './time.js'

type Json = Record<string, any>

/** 用户令牌：接入方后端签令牌接口的 `data` 原样返回即可。`expires_at` 是东八区 `YYYY-MM-DD HH:mm:ss`。 */
export interface ImToken {
  token: string
  expires_at: string
}

/** `sending` 发送中；`sent` 服务端已接收；`failed` 可 resend；`rejected` 被拉黑或被审核拒绝，不要重发。 */
export type ImMessageStatus = 'sending' | 'sent' | 'failed' | 'rejected'

export type ImConnectionState = 'connecting' | 'connected' | 'disconnected'

export interface ImMessage {
  /** 服务端消息 id；未确认（发送中 / 失败）时为 null。 */
  id: number | null
  /** 客户端生成的幂等 id，重发沿用。 */
  clientMsgId: string
  conversationId: number | null
  /** 会话内序号；未确认时为 null。 */
  seq: number | null
  from: string
  /** SDK 推导：本人在别的设备发、而本地还不知道会话对方时为空串。 */
  to: string
  isSelf: boolean
  /** `text` `image` `voice` `file` `video` `location` `custom` `recalled`，将来可能增加，不认识的请兜底显示。 */
  type: string
  /** 按 type 的内容，形状见接入文档 §5.1。 */
  content: Json
  status: ImMessageStatus
  errorCode: string | null
  errorMessage: string | null
  createdAt: number
  /** 本设备按路径发的附件的本地路径。 */
  localPath: string | null
  /** 上传附件的临时链接何时取得，SDK 用它判断要不要续。 */
  urlFetchedAt: number | null
  /** 客服消息的发送者：`agent` / `bot` / `system`；普通消息为 null。 */
  senderRole: string | null
  /** 机器人发的，内容由 AI 生成，界面上要标识。 */
  isBot: boolean
  isRecalled: boolean
  /** 谁撤回的：`sender` / `agent` / `server`；没撤回为 null。 */
  recalledBy: string | null
  /** 语音、视频的秒数，其余为 null。 */
  duration: number | null
  /** 文件名，不是文件为 null。 */
  fileName: string | null
  /** 文件、视频的字节数；还没上传完可能为 null。 */
  fileSize: number | null
}

export interface ImMessagePreview {
  seq: number
  from: string
  type: string
  preview: string
  createdAt: number
}

/** 会话对方。资料以接入方自家用户系统为准，这里是 IM 里登记的副本，昵称头像可能是空串。 */
export interface ImPeer {
  userId: string
  nickname: string
  avatarUrl: string
}

export interface ImConversation {
  id: number
  /** `c2c` 单聊 / `service` 客服，将来可能增加。 */
  type: string
  /** 会话对方；将来没有单一对方的会话（如群）为 null，请判空。 */
  peer: ImPeer | null
  /** 客服主体标识：平台客服是空串；不是客服会话为 null。 */
  serviceId: string | null
  lastMessage: ImMessagePreview | null
  maxSeq: number
  readSeq: number
  unread: number
  lastMsgAt: number
  pinnedAt: number | null
  pinned: boolean
  /** 免打扰：unread 照常计数，但不计入总未读。 */
  muted: boolean
  /** 本人清空到的序号。 */
  clearSeq: number
  /** 自己发的 `seq <= peerReadSeq` 的消息对方已读；为 null 时不要显示「已读 / 未读」。 */
  peerReadSeq: number | null
  isService: boolean
}

/** 站点开关。旧版服务端没有的按没开启。 */
export interface ImFeatures {
  /** 撤回时限（分钟），0 = 没开启。 */
  recallMinutes: number
  readReceipt: boolean
  /** 文件大小上限（MB），0 = 不能发。 */
  fileMaxMb: number
  videoMaxMb: number
}

export interface ImSendProgress {
  clientMsgId: string
  sent: number
  total: number
}

export interface ImTyping {
  conversationId: number
  from: string
  /** true 显示，false 收起。 */
  active: boolean
}

export interface ImBlockItem {
  userId: string
  createdAt: number
}

/** 举报原因编码：色情低俗、诈骗、骚扰辱骂、广告营销、违法违规、其他。 */
export const reportReasons = ['porn', 'fraud', 'harass', 'ad', 'illegal', 'other'] as const
export type ImReportReason = (typeof reportReasons)[number]

export interface ImReportResult {
  reportId: number
  /** true：对同一个人已有待处理的举报，返回的是原单，没有新建 */
  duplicated: boolean
}

export type ImCsStatus = 'none' | 'bot' | 'queued' | 'active'

export interface ImCsState {
  status: ImCsStatus
  sessionId: number
  /** 排队名次（含自己），非排队为 0。 */
  queuePosition: number
  agentsOnline: boolean
  leaveEnabled: boolean
  /** 现在可以给用户「留联系方式」的表单。 */
  canLeave: boolean
}

export interface ImCard {
  title: string
  kind: string | null
  subtitle: string | null
  image: string | null
  fields: { label: string; value: string }[]
  webLink: string | null
  appLink: string | null
  mpPath: string | null
  mpAppid: string | null
}

// ---------------- 构造与解析（内部） ----------------

type MessageDerived = 'isBot' | 'isRecalled' | 'recalledBy' | 'duration' | 'fileName' | 'fileSize'
export type MessageBase = Omit<ImMessage, MessageDerived>

const numOrNull = (v: unknown) => (typeof v === 'number' ? v : null)
const strOrNull = (v: unknown) => (typeof v === 'string' ? v : null)

export function makeMessage(b: MessageBase): ImMessage {
  const { type, content } = b
  return {
    ...b,
    isBot: b.senderRole === 'bot',
    isRecalled: type === 'recalled',
    recalledBy: type === 'recalled' ? strOrNull(content.by) : null,
    duration: type === 'voice' || type === 'video' ? numOrNull(content.duration) : null,
    fileName: type === 'file' ? strOrNull(content.name) : null,
    fileSize: type === 'file' || type === 'video' ? numOrNull(content.size) : null,
  }
}

export function patchMessage(m: ImMessage, patch: Partial<MessageBase>): ImMessage {
  return makeMessage({ ...m, ...patch })
}

/** 服务端消息没有 to：别人发来的就是我；本人发的取会话对方，不知道时为空串。 */
export function messageFromServer(j: Json, me: string, peerId?: string | null): ImMessage {
  const isSelf = j.from === me
  const content: Json = j.content ?? {}
  return makeMessage({
    id: j.id,
    clientMsgId: j.client_msg_id,
    conversationId: j.conversation_id,
    seq: j.seq,
    from: j.from,
    to: isSelf ? (peerId ?? '') : me,
    isSelf,
    type: j.type,
    content,
    status: 'sent',
    errorCode: null,
    errorMessage: null,
    createdAt: parseCst(j.created_at),
    localPath: null,
    urlFetchedAt: 'attachment_id' in content ? Date.now() : null,
    senderRole: j.sender_role ?? null,
  })
}

type ConversationDerived = 'serviceId' | 'unread' | 'pinned' | 'isService'
export type ConversationBase = Omit<ImConversation, ConversationDerived>

export function makeConversation(b: ConversationBase): ImConversation {
  return {
    ...b,
    serviceId: b.peer ? csServiceId(b.peer.userId) : null,
    unread: Math.max(0, b.maxSeq - b.readSeq),
    pinned: b.pinnedAt !== null,
    isService: b.type === 'service',
  }
}

export function patchConversation(c: ImConversation, patch: Partial<ConversationBase>): ImConversation {
  return makeConversation({ ...c, ...patch })
}

export function conversationFromServer(j: Json): ImConversation {
  const last = j.last_message
  return makeConversation({
    id: j.conversation_id,
    type: j.type,
    peer: j.peer
      ? { userId: j.peer.user_id, nickname: j.peer.nickname ?? '', avatarUrl: j.peer.avatar_url ?? '' }
      : null,
    lastMessage: last
      ? { seq: last.seq, from: last.from, type: last.type, preview: last.preview, createdAt: parseCst(last.created_at) }
      : null,
    maxSeq: j.max_seq,
    readSeq: j.read_seq,
    lastMsgAt: parseCst(j.last_msg_at),
    pinnedAt: j.pinned_at ? parseCst(j.pinned_at) : null,
    muted: j.muted ?? false,
    clearSeq: j.clear_seq ?? 0,
    peerReadSeq: j.peer_read_seq ?? null,
  })
}

export function featuresFromServer(j: Json): ImFeatures {
  const f: Json = j.features ?? {}
  return {
    recallMinutes: f.recall_minutes ?? 0,
    readReceipt: f.read_receipt ?? false,
    fileMaxMb: f.file_max_mb ?? 0,
    videoMaxMb: f.video_max_mb ?? 0,
  }
}

const CS_STATUS = ['none', 'bot', 'queued', 'active']

export function csStateFromServer(j: Json): ImCsState {
  const status: ImCsStatus = CS_STATUS.includes(j.status) ? j.status : 'none'
  const agentsOnline: boolean = j.agents_online ?? true
  const leaveEnabled: boolean = j.leave_enabled ?? false
  return {
    status,
    sessionId: j.session_id,
    queuePosition: j.queue_position,
    agentsOnline,
    leaveEnabled,
    canLeave: status === 'queued' && !agentsOnline && leaveEnabled,
  }
}

/** 会话预览文字，口径同服务端：text 前 50 字，file 连前缀合计 50，custom 取 desc 不截，不认识的空串。 */
export function previewOf(m: ImMessage): string {
  switch (m.type) {
    case 'text':
      return first50(m.content.text ?? '')
    case 'image':
      return '[图片]'
    case 'voice':
      return '[语音]'
    case 'file':
      return first50(`[文件] ${m.content.name ?? ''}`)
    case 'video':
      return '[视频]'
    case 'recalled':
      return '[消息已撤回]'
    case 'location':
      return '[位置]'
    case 'custom':
      return m.content.desc ?? ''
    default:
      return ''
  }
}

const first50 = (s: string) => Array.from(s).slice(0, 50).join('')

// ---------------- 对外工具 ----------------

/** 从客服号取主体标识：`@cs` 是空串，`@cs:<主体标识>` 是主体标识，不是客服为 null。 */
export function csServiceId(userId: string): string | null {
  if (userId === '@cs') return ''
  return userId.startsWith('@cs:') ? userId.slice(4) : null
}

/** 客服号，发消息时当对方 id 用；不传主体标识是平台客服。 */
export function csUserId(serviceId?: string | null): string {
  return serviceId ? `@cs:${serviceId}` : '@cs'
}

/** 业务卡片（接入文档 §5.9）；不是 custom、没带卡片或缺 title 为 null，退回显示 desc。 */
export function messageCard(m: Pick<ImMessage, 'type' | 'content'>): ImCard | null {
  const c = m.type === 'custom' ? m.content.data?.im_card : null
  if (!c || typeof c !== 'object' || typeof c.title !== 'string' || !c.title.trim()) return null
  const str = (k: string): string | null => (typeof c[k] === 'string' && c[k] ? c[k] : null)
  const filled = (v: unknown) => typeof v === 'string' && v !== ''
  return {
    title: c.title,
    kind: str('kind'),
    subtitle: str('subtitle'),
    image: str('image'),
    fields: (Array.isArray(c.fields) ? c.fields : [])
      .filter((f: any) => f && filled(f.label) && filled(f.value))
      .map((f: any) => ({ label: f.label, value: f.value })),
    webLink: str('web_link'),
    appLink: str('app_link'),
    mpPath: str('mp_path'),
    mpAppid: str('mp_appid'),
  }
}
