import { expect, test, vi } from 'vitest'
import type { SocketLike } from '../src/platform/types.js'
import { createRealtime, webSocketUrl, type RealtimeHooks } from '../src/realtime.js'
import { FakePlatform, flush } from './fakes.js'

let sockets: FakeSocket[] = []
class FakeSocket implements SocketLike {
  onopen: SocketLike['onopen'] = null
  onmessage: SocketLike['onmessage'] = null
  onerror: SocketLike['onerror'] = null
  onclose: SocketLike['onclose'] = null
  constructor(readonly url: string) {
    sockets.push(this)
  }
  /** 收到 connect 命令就回成功。 */
  send(data: string) {
    const { id, connect } = JSON.parse(data.split('\n')[0])
    if (connect) this.onmessage!({ data: JSON.stringify({ id, connect: { client: 'x', version: '', ping: 25, subs: { 'im:u:u1': {} } } }) })
  }
  close() {}
  open() {
    this.onopen!({})
  }
}

function setup() {
  sockets = []
  const p = new FakePlatform()
  p.WebSocket = FakeSocket as never
  const log: any[] = []
  const hooks: RealtimeHooks = {
    onConnecting: () => log.push('connecting'),
    onConnected: () => log.push('connected'),
    onDisconnected: c => log.push(c),
    onPublication: d => log.push(d),
  }
  const rt = createRealtime('wss://x', p, hooks)
  rt.connect('t1')
  return { rt, log }
}

test('地址推导', () => {
  expect(webSocketUrl('http://a:8080')).toBe('ws://a:8080/api/im/v1/connect/websocket')
  expect(webSocketUrl('https://a/x')).toBe('wss://a/x/api/im/v1/connect/websocket')
})

test('收服务端订阅的推送；处理抛错不断线', async () => {
  vi.spyOn(console, 'error').mockImplementation(() => {})
  const { log, rt } = setup()
  sockets[0].open()
  await flush()
  sockets[0].onmessage!({ data: JSON.stringify({ push: { channel: 'im:u:u1', pub: { data: { event: 'read_all' } } } }) })
  await flush()
  expect(log).toEqual(['connecting', 'connected', { event: 'read_all' }])
  rt.close()
  vi.restoreAllMocks()
})

test('已连上后收到 reason 为空的 3503：按终止处理，不无限重连', async () => {
  const { log, rt } = setup()
  sockets[0].open()
  await flush()
  sockets[0].onclose!({ code: 3503, reason: '' })
  await flush()
  expect([log[log.length - 1], sockets.length]).toEqual([3503, 1])
  rt.close()
})

test('offline + online 连发：丢掉旧连接立刻新建；close 后不再回调', async () => {
  const { log, rt } = setup()
  sockets[0].open()
  await flush()
  rt.network('offline')
  rt.network('online')
  await flush()
  expect(sockets).toHaveLength(2)
  sockets[1].open()
  await flush()
  expect(log).toEqual(['connecting', 'connected', 'connecting', 'connected'])
  rt.close()
  expect(log).toHaveLength(4)
})
