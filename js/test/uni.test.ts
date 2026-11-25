import { expect, test, vi } from 'vitest'
import { uniPlatform } from '../src/platform/uni.js'

const wait = (ms = 0) => new Promise(r => setTimeout(r, ms))

function fakeApi(over: object = {}) {
  const on: Record<string, any> = {}
  const closes: any[] = []
  const api: any = {
    requests: [] as any[],
    on, closes,
    request: (o: any) => void (api.requests.push(o), o.success({ statusCode: '200', data: '{"code":0}' })),
    uploadFile: (o: any) => void (api.requests.push(o), o.success({ statusCode: 200, data: 'ok' })),
    connectSocket: () => ({
      onOpen: (f: any) => (on.open = f), onMessage: (f: any) => (on.message = f),
      onError: (f: any) => (on.error = f), onClose: (f: any) => (on.close = f),
      send() {}, close: (o: any) => closes.push(o),
    }),
    ...over,
  }
  return api
}

function socket(api: any) {
  const got: any[] = []
  const s = new (uniPlatform(api).WebSocket)('wss://x')
  s.onopen = () => got.push('open')
  s.onclose = e => got.push(e)
  return { s, got }
}

test('传错对象报清楚；Blob 不收', () => {
  expect(() => uniPlatform({} as any)).toThrow('uni（uni-app）')
  expect(() => uniPlatform(fakeApi()).checkFile(new Blob([]))).toThrow(TypeError)
})

test('请求：字符串响应、状态转数字、没有请求体不带 data；失败是 NETWORK', async () => {
  const api = fakeApi()
  const r = { method: 'POST' as const, url: 'https://x', headers: { A: 'b' }, timeoutMs: 1000 }
  expect(await uniPlatform(api).request(r)).toEqual({ status: 200, text: '{"code":0}' })
  expect(api.requests[0]).toMatchObject({ dataType: 'text', header: { A: 'b' } })
  expect('data' in api.requests[0]).toBe(false)
  api.request = (o: any) => void o.fail(undefined)
  await expect(uniPlatform(api).request(r)).rejects.toMatchObject({ code: 'NETWORK', httpStatus: 0 })
})

test('断开码没带 reason 也补上，只回一次', async () => {
  const api = fakeApi()
  const { got } = socket(api)
  api.on.error({ errMsg: 'x' })
  api.on.close({ code: 3500, reason: '' })
  await wait(80)
  expect(got).toEqual([{ code: 3500, reason: 'code 3500' }])
})

test('只有 error 没有 close 的，补一次 1006', async () => {
  const api = fakeApi()
  const { got } = socket(api)
  api.on.error({ errMsg: '域名不合法' })
  await wait(80)
  expect(got).toEqual([{ code: 1006, reason: '域名不合法' }])
})

test('没连上就 close：连上后再关一次，不报 open；参数统一是空对象', () => {
  const api = fakeApi()
  const { s, got } = socket(api)
  s.close()
  api.on.open({})
  expect([got, api.closes]).toEqual([[], [{}, {}]])
})

test('拦截器让 connectSocket 变成 Promise 也能用', async () => {
  const api = fakeApi()
  const task = api.connectSocket()
  api.connectSocket = () => Promise.resolve(task)
  const { got } = socket(api)
  await wait()
  api.on.open({})
  expect(got).toEqual(['open'])
})

test('上传文件：路径没有扩展名的先拷成带扩展名的，传完删', async () => {
  const unlink = vi.fn()
  const api = fakeApi({
    env: { USER_DATA_PATH: 'wxfile://usr' },
    getFileSystemManager: () => ({ copyFile: (o: any) => o.success(), unlink }),
  })
  const up = (path: string) => uniPlatform(api).upload({ url: 'u', headers: {}, fields: { kind: 'file' }, file: { path }, filename: 'a.pdf', timeoutMs: 1000 })
  await up('wxfile://tmp_1')
  expect(api.requests[0].filePath).toMatch(/^wxfile:\/\/usr\/im_.*\.pdf$/)
  expect(unlink.mock.calls[0][0].filePath).toBe(api.requests[0].filePath)
  await up('wxfile://tmp_2.PDF')
  expect(api.requests[1].filePath).toBe('wxfile://tmp_2.PDF')
})

test('图片带旋转方向的对调宽高', async () => {
  const api = fakeApi({ getImageInfo: (o: any) => void o.success({ width: 40, height: 30, orientation: 'right' }) })
  expect(await uniPlatform(api).imageSize({ path: 'a' })).toEqual({ width: 30, height: 40 })
})

test('网络：断开、换网络、恢复', () => {
  let fire!: (r: object) => void
  const off = vi.fn()
  const got: object[] = []
  const stop = uniPlatform(fakeApi({ onNetworkStatusChange: (f: any) => (fire = f), offNetworkStatusChange: off })).onNetwork(c => got.push(c))
  fire({ isConnected: true, networkType: 'wifi' })
  fire({ isConnected: true, networkType: '4g' })
  fire({ isConnected: false, networkType: 'none' })
  fire({ isConnected: true, networkType: '4g' })
  expect(got).toEqual([{ online: true }, { online: true, switched: true }, { online: false }, { online: true }])
  stop()
  expect(off).toHaveBeenCalledWith(fire)
})
