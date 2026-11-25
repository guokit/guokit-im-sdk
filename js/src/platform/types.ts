/** 要发的附件：浏览器给 Blob / File（或 `blob:`、`data:` 路径），小程序与 App 给本地路径。 */
export type ImFile = Blob | { path: string; name?: string; size?: number }

export interface HttpResult {
  status: number
  text: string
}

export interface HttpRequest {
  method: 'GET' | 'POST' | 'PUT' | 'DELETE'
  url: string
  headers: Record<string, string>
  body?: string
  timeoutMs: number
}

export interface UploadRequest {
  url: string
  headers: Record<string, string>
  fields: Record<string, string>
  file: ImFile
  /** multipart 里的文件名；小程序改不了，取自路径。 */
  filename: string
  timeoutMs: number
  onProgress?: (sent: number, total: number) => void
}

/** centrifuge 只用这几个成员，close 可能在没连上时、也可能重复调。 */
export interface SocketLike {
  onopen: ((e: unknown) => void) | null
  onmessage: ((e: { data: string }) => void) | null
  onerror: ((e: unknown) => void) | null
  onclose: ((e: { code: number; reason: string }) => void) | null
  send(data: string): void
  close(): void
}

export interface NetworkChange {
  online: boolean
  /** 一直在线，但换了网络（Wi-Fi → 4G），现有连接多半已死。 */
  switched?: boolean
}

/**
 * 平台适配。请求失败（没拿到响应、超时）一律抛 `ImApiError('NETWORK', …, 0)`；
 * 不解析响应包、不管令牌。
 */
export interface ImPlatform {
  /** 退后台会被系统挂起（小程序 / App）：回来时要丢掉可能半死的连接重连。 */
  readonly suspends: boolean
  readonly WebSocket: new (url: string) => SocketLike
  request(r: HttpRequest): Promise<HttpResult>
  upload(r: UploadRequest): Promise<HttpResult>
  /** 这个平台用不了的形态，同步抛 TypeError。 */
  checkFile(f: ImFile): void
  imageSize(f: ImFile): Promise<{ width: number; height: number }>
  onVisibility(cb: (visible: boolean) => void): () => void
  onNetwork(cb: (c: NetworkChange) => void): () => void
}

export const isBlob = (f: unknown): f is Blob => typeof Blob !== 'undefined' && f instanceof Blob
