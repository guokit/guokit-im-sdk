import { expect, test } from 'vitest'
import { ImApi } from '../src/api.js'
import { TokenManager } from '../src/token.js'
import { fail, FakePlatform, flush, ok, token } from './fakes.js'

function setup() {
  const p = new FakePlatform()
  let n = 0
  const calls = { count: () => n }
  const tokens = new TokenManager(async () => token(`t${++n}`))
  return { p, tokens, calls, api: new ImApi('https://im.test', tokens, p) }
}

test('拼 URL、带令牌、成功取 data', async () => {
  const { p, api } = setup()
  p.routes['GET /conversations/3/messages'] = () => ok({ items: [], has_more: false })
  expect(await api.messages(3, { afterSeq: 5, limit: 100 })).toEqual({ items: [], hasMore: false })
  expect(p.requests[0]).toMatchObject({
    url: 'https://im.test/api/im/v1/conversations/3/messages?after_seq=5&limit=100',
    headers: { Authorization: 'Bearer t1' },
  })
  p.routes['PUT /blocks/u2'] = () => ok({})
  await api.block('u2')
  expect(p.requests[1].headers['Content-Type']).toBe('application/json')
})

test('举报：入参转蛇形、返回转驼峰，不传的字段不发', async () => {
  const { p, api } = setup()
  p.routes['POST /reports'] = () => ok({ report_id: 9, duplicated: false })
  expect(await api.report('u2', 'harass', '骚扰', [11, 12], true)).toEqual({ reportId: 9, duplicated: false })
  expect(JSON.parse(p.requests[0].body!)).toEqual({ target: 'u2', reason: 'harass', detail: '骚扰', message_ids: [11, 12], block: true })
  await api.report('u3', 'ad')
  expect(JSON.parse(p.requests[1].body!)).toEqual({ target: 'u3', reason: 'ad' })
})

test('两个请求同时 401 只换一次令牌，各重试一次', async () => {
  const { p, api, calls } = setup()
  p.routes['GET /me'] = r => (r.headers.Authorization === 'Bearer t1' ? fail('IM_TOKEN_INVALID', 401) : ok({ features: { file_max_mb: 5 } }))
  const [a, b] = await Promise.all([api.features(), api.features()])
  expect([a.fileMaxMb, b.fileMaxMb, calls.count()]).toEqual([5, 5, 2])
})

test('业务失败、坏响应包、401 但不是令牌问题都照抛', async () => {
  const { p, api, calls } = setup()
  p.routes['POST /conversations/read-all'] = () => fail('IM_RATE_LIMITED')
  await expect(api.markAllRead()).rejects.toMatchObject({ code: 'IM_RATE_LIMITED', isTemporary: true })
  p.routes['POST /conversations/read-all'] = () => ({ status: 413, text: '<html>' })
  await expect(api.markAllRead()).rejects.toMatchObject({ code: 'BAD_RESPONSE', httpStatus: 413 })
  p.routes['POST /conversations/read-all'] = () => fail('IM_KEY_INVALID', 401)
  await expect(api.markAllRead()).rejects.toMatchObject({ code: 'IM_KEY_INVALID' })
  expect(calls.count()).toBe(1)
})

test('登出后在途请求遇 401 不换令牌、不重发', async () => {
  const { p, api, calls } = setup()
  let reply!: (r: ReturnType<typeof ok>) => void
  p.routes['POST /messages'] = () => new Promise(r => (reply = r))
  const sending = api.sendMessage('u2', 'text', { text: 'x' }, 'c1')
  await flush()
  api.close()
  reply(fail('IM_TOKEN_INVALID', 401))
  await expect(sending).rejects.toMatchObject({ name: 'ImClosedError' })
  expect([calls.count(), p.requests.length]).toEqual([1, 1])
})

test('令牌：过期时间坏的不缓存，清理后迟到的结果不写回', async () => {
  const bad = new TokenManager(async () => ({ token: 'x', expires_at: '坏' }))
  await expect(bad.current()).rejects.toThrow()
  expect(bad.cached).toBeNull()
  const tm = new TokenManager(async () => token('a'))
  const p = tm.current()
  tm.clear()
  expect(await p).toBe('a')
  expect(tm.cached).toBeNull()
})
