import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { GuokitIm, type ImEvents } from '../src/client.js'
import { ImKickedOutError } from '../src/errors.js'
import type { Realtime, RealtimeFactory, RealtimeHooks } from '../src/realtime.js'
import { fail, FakePlatform, flush, ok, token } from './fakes.js'

class FakeRt implements Realtime {
  tokens: string[] = []
  events: string[] = []
  closed = false
  constructor(public hooks: RealtimeHooks, private bad: () => boolean) {}
  connect(t: string) {
    this.tokens.push(t)
    if (this.bad()) this.hooks.onDisconnected(3500)
    else this.hooks.onConnected()
  }
  network(e: string) {
    this.events.push(e)
  }
  close() {
    this.closed = true
  }
}

let p: FakePlatform, im: GuokitIm, rts: FakeRt[], bad: boolean, provider: () => any, seen: [keyof ImEvents, any][]
const at = '2026-11-20 10:00:00'
const convRaw = (over: object = {}) => ({
  conversation_id: 1, type: 'c2c', peer: { user_id: 'u2' }, last_message: null, max_seq: 0, read_seq: 0, last_msg_at: at, ...over,
})
const of = (e: keyof ImEvents) => seen.filter(x => x[0] === e).map(x => x[1])

class TestIm extends GuokitIm {
  protected realtimeFactory: RealtimeFactory = (_url, _p, hooks) => {
    const rt = new FakeRt(hooks, () => bad)
    rts.push(rt)
    return rt
  }
}

beforeEach(() => {
  vi.spyOn(console, 'warn').mockImplementation(() => {})
  p = new FakePlatform()
  const empty = () => ok({ items: [], next_cursor: '', has_more: false })
  p.routes = {
    'GET /conversations': () => ok({ items: [convRaw({ max_seq: 3 })], next_cursor: '' }),
    'GET /conversations/changes': empty,
    'GET /recalls': empty,
  }
  rts = []
  bad = false
  seen = []
  let n = 0
  provider = () => token(`t${++n}`)
  im = new TestIm({ baseUrl: 'https://im.test/', tokenProvider: () => provider(), platform: p })
  for (const e of ['newMessage', 'messageUpdated', 'conversations', 'totalUnread', 'connection', 'kickedOut', 'typing'] as const) {
    im.on(e, v => seen.push([e, v]))
  }
})
afterEach(() => {
  im.dispose()
  vi.restoreAllMocks()
})

test('登录：推初值、连上后对账；登出总未读归零、监听退订', async () => {
  await im.login('u1')
  await flush()
  expect(of('connection')).toEqual(['connecting', 'connected'])
  expect(of('totalUnread')).toEqual([0, 3])
  expect([im.currentUserId, im.conversations()[0].unread]).toEqual(['u1', 3])
  im.logout()
  await flush()
  expect(of('totalUnread')).toEqual([0, 3, 0])
  expect([rts[0].closed, p.visibility.length, p.network.length, im.currentUserId]).toEqual([true, 0, 0, null])
  expect(() => im.conversations()).toThrow('未登录')
})

test('3500 换令牌重连 2 次后停，清掉坏令牌；再 login 会重新取', async () => {
  bad = true
  await im.login('u1')
  await flush()
  expect(rts[0].tokens).toEqual(['t1', 't2', 't3'])
  expect(im.connectionState).toBe('disconnected')
  bad = false
  await im.login('u1')
  expect([rts[0].tokens[3], im.connectionState]).toEqual(['t4', 'connected'])
})

test('3503 与 tokenProvider 抛 ImKickedOutError：先断开再发 kickedOut，不再重连', async () => {
  await im.login('u1')
  rts[0].hooks.onDisconnected(3503)
  expect(rts[0].closed).toBe(true)
  await flush()
  p.network[0]({ online: true })
  expect([of('kickedOut').length, rts.length, im.connectionState]).toEqual([1, 1, 'disconnected'])
  provider = () => { throw new ImKickedOutError() }
  await im.login('u2')
  await flush()
  expect(of('kickedOut').length).toBe(2)
})

test('kickedOut 监听器里登出再登录别的账号，不影响新会话', async () => {
  im.on('kickedOut', () => {
    im.logout()
    void im.login('u2')
  })
  await im.login('u1')
  rts[0].hooks.onDisconnected(3503)
  await flush()
  expect([im.currentUserId, im.connectionState, rts[1].closed]).toEqual(['u2', 'connected', false])
})

test('换号：旧账号在途的结果不进新账号', async () => {
  await im.login('u1')
  await flush()
  let reply!: (r: any) => void
  p.routes['GET /conversations/1/messages'] = () => new Promise(r => (reply = r))
  const loading = im.messages(1)
  await flush()
  p.routes['GET /conversations'] = () => ok({ items: [], next_cursor: '' })
  await im.login('u2')
  reply(ok({ items: [], has_more: false }))
  await expect(loading).rejects.toThrow('已登出')
  rts[0].hooks.onPublication({ event: 'read_all' })
  rts[0].hooks.onDisconnected(3503)
  await flush()
  expect([im.currentUserId, im.connectionState, im.conversations()]).toEqual(['u2', 'connected', []])
})

test('前后台：离开 10 秒以上丢连接重连，不足只补对账；浏览器不丢', async () => {
  await im.login('u1')
  await flush()
  const now = vi.spyOn(Date, 'now')
  const leave = (ms: number) => {
    now.mockReturnValue(1e12)
    p.visibility[0](false)
    now.mockReturnValue(1e12 + ms)
    p.visibility[0](true)
  }
  leave(3000)
  expect(rts[0].events).toEqual(['online'])
  leave(60_000)
  expect(rts[0].events).toEqual(['online', 'offline', 'online'])
  p.network[0]({ online: true, switched: true })
  expect(rts[0].events.slice(3)).toEqual(['offline', 'online'])
  p.suspends = false
  leave(60_000)
  expect(rts[0].events.slice(5)).toEqual(['online'])
})

test('取令牌失败报 disconnected，恢复网络时自动再连', async () => {
  const good = provider
  provider = () => { throw new Error('断网') }
  await im.login('u1')
  expect(im.connectionState).toBe('disconnected')
  provider = good
  p.network[0]({ online: true })
  await flush()
  expect(im.connectionState).toBe('connected')
})

test('正在输入：显示后到期收起', async () => {
  await im.login('u1')
  rts[0].hooks.onPublication({ event: 'typing', conversation_id: 1, from: 'u2', expires_in: 0.01 })
  await new Promise(r => setTimeout(r, 30))
  expect(of('typing').map(t => t.active)).toEqual([true, false])
})

test('一键清未读后打开会话仍上报一次已读', async () => {
  await im.login('u1')
  await flush()
  p.routes['POST /conversations/read-all'] = () => ok({ updated: 1 })
  p.routes['POST /conversations/1/read'] = () => ok({ read_seq: 3, unread: 0 })
  await im.markAllRead()
  await im.markRead(1)
  await im.markRead(1)
  expect(p.requests.filter(r => r.url.endsWith('/conversations/1/read'))).toHaveLength(1)
})

test('参数错误同步抛，服务端拒绝走 rejects', async () => {
  expect(() => new GuokitIm({ baseUrl: 'im.test', tokenProvider: provider, platform: p })).toThrow(TypeError)
  expect(() => new GuokitIm({ baseUrl: 'https://im.test', tokenProvider: provider })).toThrow('uniPlatform')
  await im.login('u1')
  expect(() => im.rateCs(1, 6)).toThrow(RangeError)
  expect(() => im.leaveCs({ name: '张三' })).toThrow('至少填一项')
  expect(() => im.leaveCs({ email: '长'.repeat(41) })).toThrow('120 字节')
  p.routes['POST /handoff'] = () => fail('VALIDATION', 400)
  await expect(im.handoffCs()).rejects.toMatchObject({ code: 'VALIDATION' })
})
