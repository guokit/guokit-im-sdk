import type { HttpRequest, HttpResult, ImFile, ImPlatform, NetworkChange, UploadRequest } from '../src/platform/types.js'

export const token = (t: string) => ({ token: t, expires_at: '2099-01-01 00:00:00' })
export const ok = (data: unknown): HttpResult => ({ status: 200, text: JSON.stringify({ code: 0, message: 'ok', data }) })
export const fail = (code: string, status = 200): HttpResult => ({ status, text: JSON.stringify({ code, message: code, data: {} }) })

type Reply = HttpResult | Error | Promise<HttpResult>

/** 假平台：按「方法 路径」给响应，记下全部请求。 */
export class FakePlatform implements ImPlatform {
  suspends = true
  WebSocket = null as never
  requests: HttpRequest[] = []
  uploads: UploadRequest[] = []
  routes: Record<string, (r: HttpRequest) => Reply> = {}
  onUpload: (r: UploadRequest) => Reply = () => ok({ attachment_id: 7, ticket: 't7', url: 'https://x/7' })
  visibility: ((v: boolean) => void)[] = []
  network: ((c: NetworkChange) => void)[] = []

  async request(r: HttpRequest): Promise<HttpResult> {
    this.requests.push(r)
    const path = r.url.replace(/^https?:\/\/[^/]+\/api\/(im|imcs)\/v1/, '').replace(/\?.*/, '')
    const h = this.routes[`${r.method} ${path}`]
    if (!h) throw new Error(`没有准备 ${r.method} ${path}`)
    const x = await h(r)
    if (x instanceof Error) throw x
    return x
  }

  async upload(r: UploadRequest): Promise<HttpResult> {
    this.uploads.push(r)
    const x = await this.onUpload(r)
    if (x instanceof Error) throw x
    return x
  }

  checkFile(f: ImFile) {
    if (f instanceof Blob) throw new TypeError('只收路径')
  }
  async imageSize() {
    return { width: 10, height: 20 }
  }
  onVisibility(cb: (v: boolean) => void) {
    this.visibility.push(cb)
    return () => void (this.visibility = this.visibility.filter(f => f !== cb))
  }
  onNetwork(cb: (c: NetworkChange) => void) {
    this.network.push(cb)
    return () => void (this.network = this.network.filter(f => f !== cb))
  }
}

export const flush = () => new Promise<void>(r => setTimeout(r))
