import { beforeEach, expect, test } from 'vitest'
import { ImApi } from '../src/api.js'
import type { ImMessage } from '../src/models.js'
import { Store } from '../src/store.js'
import { Sync } from '../src/sync.js'
import { TokenManager } from '../src/token.js'
import { fail, FakePlatform, ok, token } from './fakes.js'

const at = '2026-11-20 10:00:00'
const convRaw = (over: object = {}) => ({
  conversation_id: 1, type: 'c2c', peer: { user_id: 'u2' }, last_message: null, max_seq: 0, read_seq: 0, last_msg_at: at, clear_seq: 0, ...over,
})
const msgRaw = (seq: number, over: object = {}) => ({
  id: 100 + seq, conversation_id: 1, seq, from: 'u2', type: 'text', content: { text: `m${seq}` }, client_msg_id: `c${seq}`, created_at: at, ...over,
})
const recalledRaw = (seq: number) => msgRaw(seq, { type: 'recalled', content: { by: 'sender' } })
const push = (seq: number, over: object = {}) => ({ event: 'message', conversation_id: 1, seq, message: msgRaw(seq, over) })

let p: FakePlatform, store: Store, sync: Sync, news: string[], updated: ImMessage[], list: object[], server: object[]

beforeEach(() => {
  p = new FakePlatform()
  store = new Store()
  news = []
  updated = []
  list = [convRaw()]
  server = []
  const api = new ImApi('https://im.test', new TokenManager(async () => token('t')), p)
  sync = new Sync(api, store, 'u1', {
    onNewMessage: m => news.push(m.content.text), onMessageUpdated: m => updated.push(m), onChanged() {}, onError() {}, onTyping() {}, onFriendPush() {},
  })
  const empty = () => ok({ items: [], next_cursor: '', has_more: false })
  p.routes = {
    'GET /conversations': () => ok({ items: list, next_cursor: '' }),
    'GET /conversations/changes': empty,
    'GET /recalls': empty,
    'GET /conversations/1/messages': r => {
      const after = Number(/after_seq=(\d+)/.exec(r.url)![1])
      return ok({ items: server.filter((m: any) => m.seq > after), has_more: false })
    },
  }
})

test('新会话的推送：拉一次列表带出会话再入库，重复推送只发一次事件', async () => {
  sync.handlePush(push(1))
  sync.handlePush(push(1))
  await sync.idle
  expect(news).toEqual(['m1'])
  expect(store.conversation(1)).toMatchObject({ maxSeq: 1, unread: 1, peer: { userId: 'u2' } })
})

test('拉列表失败：不建占位会话，消息与事件照常，随后对账补上', async () => {
  let n = 0
  p.routes['GET /conversations'] = () => (n++ === 0 ? fail('INTERNAL', 500) : ok({ items: [convRaw({ max_seq: 1 })], next_cursor: '' }))
  sync.handlePush(push(1))
  await sync.idle
  await sync.idle
  expect([news, store.conversation(1)!.unread]).toEqual([['m1'], 1])
})

test('会话列表翻到一半失败，下次对账接着翻完', async () => {
  const pages: Record<string, object> = {
    '': ok({ items: [convRaw({ max_seq: 1 })], next_cursor: 'p2' }),
    p2: ok({ items: [convRaw({ conversation_id: 2, peer: { user_id: 'u3' } })], next_cursor: '' }),
  }
  let bad = true
  p.routes['GET /conversations'] = r => {
    const c = /cursor=(\w+)/.exec(r.url)?.[1] ?? ''
    return c && bad ? fail('INTERNAL', 502) : (pages[c] as any)
  }
  await sync.reconcile()
  bad = false
  await sync.reconcile()
  expect(store.conversations()).toHaveLength(2)
})

test('新会话首条由本设备发出，没调过 messages()：断线期间的消息照样补', async () => {
  list = [convRaw({ max_seq: 1 })]
  sync.ingest(1, [msgRaw(1, { from: 'u1' })], false)
  await sync.ensureConversation(1)
  sync.handlePush(push(2))
  await sync.idle
  list = [convRaw({ max_seq: 4 })]
  server = [msgRaw(3), msgRaw(4)]
  await sync.reconcile()
  expect(news).toEqual(['m2', 'm3', 'm4'])
})

test('跳号补拉中间段，按序发事件', async () => {
  store.upsertConversations([])
  sync.handlePush(push(1))
  await sync.idle
  store.setSyncedSeq(1, 1)
  server = [msgRaw(2), msgRaw(3)]
  sync.handlePush(push(4))
  await sync.idle
  expect(news).toEqual(['m1', 'm2', 'm3', 'm4'])
  expect(store.syncedSeq(1)).toBe(4)
})

test('对账：落后的补拉；老服务端没有增量接口也不影响', async () => {
  await sync.reconcile()
  store.setSyncedSeq(1, 0)
  sync.handlePush(push(1))
  await sync.idle
  store.setSyncedSeq(1, 1)
  list = [convRaw({ max_seq: 3 })]
  server = [msgRaw(2), recalledRaw(3)]
  p.routes['GET /conversations/changes'] = () => ({ status: 200, text: '<html>' })
  p.routes['GET /recalls'] = () => ({ status: 200, text: '<html>' })
  await sync.reconcile()
  expect(news).toEqual(['m1', 'm2']) // 离线期间「发了又撤」的不弹新消息
  expect(updated.map(m => m.seq)).toEqual([3])
})

test('没有 peer 的会话（将来的群）：对账与推送都不抛错', async () => {
  list = [convRaw({ type: 'group', peer: undefined, max_seq: 1 })]
  await sync.reconcile()
  sync.handlePush(push(2))
  await sync.idle
  expect([store.conversations().length, news]).toEqual([1, ['m2']])
})

test('撤回增量：只改本地已有的与预览；重复给只发一次', async () => {
  list = [convRaw({ max_seq: 2, last_message: { seq: 2, from: 'u2', type: 'text', preview: 'm2', created_at: at } })]
  await sync.reconcile()
  sync.ingest(1, [msgRaw(1)], false)
  const page = ok({
    items: [1, 2, 9].map(seq => ({ conversation_id: 1, message_id: 100 + seq, seq, message: recalledRaw(seq) })),
    next_cursor: 'x', has_more: false,
  })
  p.routes['GET /recalls'] = () => page
  await sync.reconcile()
  await sync.reconcile()
  expect(updated.map(m => m.seq)).toEqual([1])
  expect(store.messages(1, 30).map(m => m.seq)).toEqual([1])
  expect(store.conversation(1)!.lastMessage!.preview).toBe('[消息已撤回]')
})

test('删除后迟到的旧消息挡住，新消息让会话重新出现', async () => {
  list = [convRaw({ max_seq: 2 })]
  await sync.reconcile()
  await sync.applySettings({ conversation_id: 1, clear_seq: 2, visible: false, pinned_at: null, muted: false })
  sync.ingest(1, [msgRaw(1), msgRaw(2)], true)
  expect([store.conversations().length, news]).toEqual([0, []])
  list = [convRaw({ max_seq: 3, clear_seq: 2 })]
  sync.handlePush(push(3))
  await sync.idle
  expect([store.conversation(1)!.maxSeq, news]).toEqual([3, ['m3']])
})

test('登出后队列里剩下的跳过', async () => {
  sync.handlePush(push(1))
  sync.close()
  await sync.idle
  expect([news, p.requests.length]).toEqual([[], 0])
})
