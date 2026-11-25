import { ImApiError } from '../errors.js'
import { browserPlatform, isBrowser } from './browser.js'
import { isBlob, type HttpResult, type ImFile, type ImPlatform, type SocketLike } from './types.js'

/** `uni` 或 `wx` 里要用到的接口。uni 是只有 get 的 Proxy：能力只能用 typeof 判断，不能用 in。 */
export interface UniLike {
  request(o: any): any
  uploadFile(o: any): any
  connectSocket(o: any): any
  getImageInfo?(o: any): any
  onAppShow?(fn: () => void): void
  offAppShow?(fn: () => void): void
  onAppHide?(fn: () => void): void
  offAppHide?(fn: () => void): void
  onNetworkStatusChange?(fn: (r: any) => void): void
  offNetworkStatusChange?(fn: (r: any) => void): void
  getFileSystemManager?(): any
  env?: { USER_DATA_PATH?: string }
}

const network = (e: any, fallback: string) => new ImApiError('NETWORK', e?.errMsg ?? fallback, 0)
const has = (api: any, k: string) => typeof api[k] === 'function'
const isThenable = (x: any) => !!x && typeof x.then === 'function'
const pathOf = (f: ImFile) => (f as { path: string }).path
const extOf = (name: string) => /\.[A-Za-z0-9]+$/.exec(name)?.[0].toLowerCase() ?? ''

/**
 * uni-app（`uniPlatform(uni)`）与微信原生小程序（`uniPlatform(wx)`）。
 * uni-app H5 返回浏览器平台：H5 正式构建默认开 treeShaking，当参数传进来的 uni 是空对象。
 */
export function uniPlatform(api: UniLike): ImPlatform {
  if (isBrowser()) return browserPlatform()
  if (!api || !has(api, 'request') || !has(api, 'connectSocket')) {
    throw new TypeError('uniPlatform 要传 uni（uni-app）或 wx（微信原生小程序）')
  }
  const watch = (on: keyof UniLike, off: keyof UniLike, fn: (r: any) => void) => {
    if (!has(api, on)) return () => {}
    ;(api as any)[on](fn)
    // 必须传同一个函数：不传会移除接入方自己的监听
    return () => {
      if (has(api, off)) (api as any)[off](fn)
    }
  }

  return {
    suspends: true,
    WebSocket: socketClass(api),

    request: ({ method, url, headers, body, timeoutMs }) =>
      call(timeoutMs, '请求超时', (resolve, reject) => {
        const o: any = {
          url, method, header: { ...headers }, timeout: timeoutMs, dataType: 'text', responseType: 'text',
          success: (r: any) => resolve({ status: Number(r.statusCode), text: String(r.data) }),
          fail: (e: any) => reject(network(e, '请求失败')), // 入参可能是 undefined；退后台的 interrupted 也走这里
        }
        if (body !== undefined) o.data = body
        catchThenable(api.request(o), reject)
      }),

    upload: async ({ url, headers, fields, file, filename, timeoutMs, onProgress }) => {
      const { path, done } = await withExtension(api, pathOf(file), filename)
      try {
        return await call(timeoutMs, '上传超时', (resolve, reject) => {
          const task = api.uploadFile({
            url, name: 'file', filePath: path, formData: fields, header: { ...headers }, timeout: timeoutMs,
            success: (r: any) => resolve({ status: Number(r.statusCode), text: String(r.data) }),
            fail: (e: any) => reject(network(e, '上传失败')),
          })
          catchThenable(task, reject)
          // 接入方装了异步 addInterceptor 时拿到的是 Promise，没有进度
          if (onProgress && task && has(task, 'onProgressUpdate')) {
            task.onProgressUpdate((p: any) => onProgress(p.totalBytesSent, p.totalBytesExpectedToSend))
          }
        })
      } finally {
        done()
      }
    },

    checkFile(f) {
      if (!f || isBlob(f) || !pathOf(f)) throw new TypeError('小程序与 App 里附件请传 { path: 本地路径 }')
    },

    imageSize: f =>
      new Promise((resolve, reject) => {
        if (!has(api, 'getImageInfo')) return reject(new Error('平台没有 getImageInfo'))
        catchThenable(api.getImageInfo!({
          src: pathOf(f),
          success: (r: any) => {
            // 给的是没按 EXIF 旋转的宽高，左右旋转 90 度的要对调
            const turned = /^(left|right)/.test(r.orientation ?? '')
            resolve(turned ? { width: r.height, height: r.width } : { width: r.width, height: r.height })
          },
          fail: (e: any) => reject(new Error(e?.errMsg ?? '取图片宽高失败')),
        }), reject)
      }),

    onVisibility(cb) {
      const offs = [watch('onAppShow', 'offAppShow', () => cb(true)), watch('onAppHide', 'offAppHide', () => cb(false))]
      return () => offs.forEach(f => f())
    },

    onNetwork(cb) {
      let type: string | null = null
      return watch('onNetworkStatusChange', 'offNetworkStatusChange', r => {
        const online = r.isConnected !== false && r.networkType !== 'none'
        const switched = online && type !== null && type !== 'none' && type !== r.networkType
        type = online ? r.networkType : 'none'
        cb(switched ? { online, switched } : { online })
      })
    },
  }
}

/** 兜一层超时：有的平台不认 timeout 参数。 */
function call(timeoutMs: number, what: string, run: (resolve: (r: HttpResult) => void, reject: (e: unknown) => void) => void): Promise<HttpResult> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new ImApiError('NETWORK', `${what}（${timeoutMs / 1000} 秒）`, 0)), timeoutMs + 1000)
    run(
      r => (clearTimeout(timer), resolve(r)),
      e => (clearTimeout(timer), reject(e)),
    )
  })
}

/** 拦截器把接口变成 Promise 时，它的失败也算失败（回调照样会走，重复无害）。 */
function catchThenable(r: any, reject: (e: unknown) => void): void {
  if (isThenable(r)) r.then(undefined, (e: any) => reject(network(e, '请求失败')))
}

/**
 * multipart 的文件名取自路径、改不了，而服务端按它核扩展名。路径没带对扩展名时，先拷成带扩展名的再传。
 * 拷不了就原样传，由服务端报错。
 */
async function withExtension(api: UniLike, path: string, filename: string): Promise<{ path: string; done: () => void }> {
  const ext = extOf(filename)
  const dir = api.env?.USER_DATA_PATH
  if (!ext || extOf(path) === ext || !dir || !has(api, 'getFileSystemManager')) return { path, done: () => {} }
  const fs = api.getFileSystemManager!()
  const dest = `${dir}/im_${Date.now()}_${Math.random().toString(36).slice(2, 8)}${ext}`
  return new Promise(resolve => {
    fs.copyFile({
      srcPath: path, destPath: dest,
      success: () => resolve({ path: dest, done: () => fs.unlink({ filePath: dest, fail: () => {} }) }),
      fail: () => resolve({ path, done: () => {} }),
    })
  })
}

/** 把 SocketTask 包成 centrifuge 要的 WebSocket。 */
function socketClass(api: UniLike): new (url: string) => SocketLike {
  return class implements SocketLike {
    onopen: SocketLike['onopen'] = null
    onmessage: SocketLike['onmessage'] = null
    onerror: SocketLike['onerror'] = null
    onclose: SocketLike['onclose'] = null
    private task: any = null
    private closed = false
    private ended = false

    constructor(url: string) {
      const fail = (e: any) => this.failed(e)
      const r = api.connectSocket({ url, success() {}, fail, complete() {} })
      if (r && has(r, 'onOpen')) this.bind(r)
      else if (isThenable(r)) r.then((t: any) => (t && has(t, 'onOpen') ? this.bind(t) : fail(null)), fail)
      else fail(null)
    }

    private bind(task: any): void {
      this.task = task
      task.onOpen((e: any) => {
        // 没连上就 close 的：那时平台还没有连接可关，现在补关，否则漏一个（微信上限 5 个）
        if (this.closed) return this.closeTask()
        this.onopen?.(e)
      })
      task.onMessage((m: any) => this.onmessage?.({ data: m.data }))
      task.onError((e: any) => this.failed(e))
      task.onClose((e: any) => this.end(Number(e?.code) || 1006, e?.reason))
      if (this.closed) this.closeTask()
    }

    /** 有的平台出错后不再有 close。晚一拍再补，让真正的断开码先到。 */
    private failed(e: any): void {
      setTimeout(() => {
        if (this.ended) return
        this.onerror?.(e)
        this.end(1006, e?.errMsg)
      }, 50)
    }

    private end(code: number, reason: unknown): void {
      if (this.ended) return
      this.ended = true
      // centrifuge 只在 reason 非空且不是 JSON 时才判断「不重连」，空着会让 3500 / 3503 变成无限重连
      const text = typeof reason === 'string' && reason ? reason : code >= 3000 ? `code ${code}` : ''
      this.onclose?.({ code, reason: text })
    }

    send(data: string): void {
      this.task?.send({ data, fail: () => {} })
    }

    close(): void {
      this.closed = true
      this.closeTask()
    }

    private closeTask(): void {
      try {
        this.task?.close({})
      } catch {
        // 还没连上就关，有的平台会抛
      }
    }
  }
}
