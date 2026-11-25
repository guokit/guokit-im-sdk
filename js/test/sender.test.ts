import { beforeEach, expect, test } from 'vitest'
import { ImApi } from '../src/api.js'
import { ImKickedOutError } from '../src/errors.js'
import type { ImMessage, ImSendProgress } from '../src/models.js'
import { Sender, uuid } from '../src/sender.js'
import { Store } from '../src/store.js'
import { Sync } from '../src/sync.js'
import { TokenManager } from '../src/token.js'
import { fail, FakePlatform, flush, ok, token } from './fakes.js'

const at = '2026-11-20 10:00:00'
let p: FakePlatform, store: Store, sync: Sync, api: ImApi, sender: Sender, updated: ImMessage[], progress: ImSendProgress[], kicked: number, closed: boolean
let provider: () => any
const bodies = () => p.requests.filter(r => r.method === 'POST' && r.url.endsWith('/messages')).map(r => JSON.parse(r.body!))

beforeEach(() => {
  p = new FakePlatform()
  store = new Store()
  updated = []
  progress = []
  kicked = 0
  closed = false
  provider = () => token('t')
  api = new ImApi('https://im.test', new TokenManager(() => provider()), p)
  sync = new Sync(api, store, 'u1', { onNewMessage() {}, onMessageUpdated() {}, onChanged() {}, onError() {}, onTyping() {} })
  sender = new Sender(api, store, sync, p, 'u1', {
    onUpdated: m => updated.push(m), onSnapshot() {}, onKickedOut: () => kicked++, onProgress: x => progress.push(x), closed: () => closed,
  })
  p.routes = {
    'POST /messages': r => {
      const b = JSON.parse(r.body!)
      return ok({ id: 9, conversation_id: 1, seq: 5, from: 'u1', type: b.type, content: b.content, client_msg_id: b.client_msg_id, created_at: at })
    },
    'GET /conversations': () => ok({
      items: [{ conversation_id: 1, type: 'c2c', peer: { user_id: 'u2' }, last_message: null, max_seq: 5, read_seq: 5, last_msg_at: at }], next_cursor: '',
    }),
  }
})

test('文本：发送中 → sent，本地没有会话时带出来', async () => {
  const m = await sender.text('u2', '你好')
  expect(updated.map(x => x.status)).toEqual(['sending', 'sent'])
  expect(m).toMatchObject({ status: 'sent', seq: 5, to: 'u2' })
  await sync.idle
  expect(store.conversationByPeer('u2')!.id).toBe(1)
})

test('网络失败可重发且沿用 clientMsgId，发送中不重复发；被拉黑是 rejected', async () => {
  const route = p.routes['POST /messages']
  p.routes['POST /messages'] = () => fail('INTERNAL', 500)
  const m = await sender.text('u2', 'x')
  expect(m).toMatchObject({ status: 'failed', errorCode: 'INTERNAL' })
  p.routes['POST /messages'] = route
  const first = sender.resend(m)
  expect((await sender.resend(m)).status).toBe('sending')
  expect((await first).status).toBe('sent')
  const sent = bodies()
  expect([sent.length, sent[0].client_msg_id === sent[1].client_msg_id]).toEqual([2, true])
  p.routes['POST /messages'] = () => fail('IM_BLOCKED')
  const r = await sender.text('u2', 'y')
  expect(r.status).toBe('rejected')
  expect(() => sender.resend(r)).toThrow(TypeError)
})

test('图片：取宽高、上传、只带该带的键；失败重发不再上传', async () => {
  p.routes['POST /messages'] = () => fail('INTERNAL', 500)
  const m = await sender.image('u2', { path: '/a/b.png' }, {})
  expect(p.uploads[0]).toMatchObject({ filename: 'b.png', fields: { kind: 'image' } })
  expect(bodies()[0].content).toEqual({ attachment_id: 7, ticket: 't7', width: 10, height: 20 })
  await sender.resend(m)
  expect(p.uploads).toHaveLength(1)
})

test('文件：消息里的名字与上传名，进度；拿不到名字同步抛', async () => {
  p.onUpload = r => (r.onProgress!(5, 10), ok({ attachment_id: 7, ticket: 't', url: 'u' }))
  const m = await sender.file('u2', { path: 'wxfile://tmp_1.pdf' }, '合同.pdf')
  expect([p.uploads[0].filename, bodies()[0].content.name]).toEqual(['合同.pdf', '合同.pdf'])
  expect(progress).toEqual([{ clientMsgId: m.clientMsgId, sent: 5, total: 10 }])
  expect(() => sender.file('u2', { path: 'wxfile://tmp_1' })).toThrow('请传 name')
})

test('视频：封面不被接受就不带封面；时长取整，越界同步抛', async () => {
  p.onUpload = r => (r.fields.kind === 'image' ? fail('VALIDATION', 400) : ok({ attachment_id: 7, ticket: 't', url: 'u' }))
  await sender.video('u2', { path: 'a.mp4' }, { durationMs: 300, width: 100.4, height: 50, cover: { path: 'c.jpg' } })
  expect(bodies()[0].content).toEqual({ attachment_id: 7, ticket: 't', duration: 1, width: 100, height: 50 })
  expect(() => sender.voice('u2', { path: 'a.mp3' }, 61_000)).toThrow(RangeError)
  expect(() => sender.image('u2', new Blob([]), {})).toThrow(TypeError)
})

test('provider 说被踢：失败并走踢下线；登出后在途的失败为 UNKNOWN', async () => {
  provider = () => { throw new ImKickedOutError() }
  expect(await sender.text('u2', 'x')).toMatchObject({ status: 'failed', errorCode: 'KICKED_OUT' })
  expect(kicked).toBe(1)
  provider = () => token('t')
  let reply!: (r: any) => void
  p.routes['POST /messages'] = () => new Promise(r => (reply = r))
  const sending = sender.text('u2', 'y')
  await flush()
  api.close()
  closed = true
  reply(ok({}))
  expect(await sending).toMatchObject({ status: 'failed', errorCode: 'UNKNOWN' })
})

test('推送先到、HTTP 后失败：不降级成 failed', async () => {
  let reply!: (r: any) => void
  p.routes['POST /messages'] = () => new Promise(r => (reply = r))
  const sending = sender.text('u2', 'x')
  await flush()
  const { client_msg_id } = bodies()[0]
  sync.ingest(1, [{ id: 9, conversation_id: 1, seq: 5, from: 'u1', type: 'text', content: { text: 'x' }, client_msg_id, created_at: at }], true)
  reply(fail('INTERNAL', 500))
  expect((await sending).status).toBe('sent')
})

test('链接超过 20 小时重拉；没有封面的视频不重拉', async () => {
  const raw = (url: string) => ({ id: 9, conversation_id: 1, seq: 5, from: 'u2', type: 'image', content: { attachment_id: 7, url }, client_msg_id: 'c', created_at: at })
  sync.ingest(1, [raw('old')], false)
  const m = store.messageById(9)!
  expect(await sender.mediaUrl(m, 'image')).toBe('old')
  store.upsertMessage({ ...m, urlFetchedAt: 1 })
  p.routes['GET /conversations/1/messages'] = () => ok({ items: [raw('new')], has_more: false })
  updated = []
  expect(await sender.mediaUrl(m, 'image')).toBe('new')
  store.upsertMessage({ ...m, content: { attachment_id: 7, url: 'new' }, urlFetchedAt: 1 })
  expect([await sender.mediaUrl(m, 'image'), updated.length]).toEqual(['new', 1]) // 地址没变不再发事件
  expect(await sender.mediaUrl({ ...m, id: null, type: 'video', content: { attachment_id: 7, cover_attachment_id: 0, cover_url: '' } }, 'video', 'cover_url')).toBeNull()
})

test('clientMsgId 形状', () => {
  expect(uuid()).toMatch(/^[0-9a-f-]{36}$/)
  const c = globalThis.crypto
  Object.defineProperty(globalThis, 'crypto', { value: undefined, configurable: true })
  const ids = new Set(Array.from({ length: 500 }, uuid))
  Object.defineProperty(globalThis, 'crypto', { value: c, configurable: true })
  expect(ids.size).toBe(500)
  for (const id of ids) expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$/)
})
