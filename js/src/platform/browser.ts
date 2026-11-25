import { ImApiError } from '../errors.js'
import { isBlob, type ImFile, type ImPlatform, type SocketLike } from './types.js'

const network = (message: string) => new ImApiError('NETWORK', message, 0)

const toBlob = async (f: ImFile): Promise<Blob> => {
  if (isBlob(f)) return f
  try {
    return await (await fetch(f.path)).blob()
  } catch {
    throw network('读取文件失败')
  }
}

const hasDom = () => typeof document !== 'undefined' && typeof document.createElement === 'function'

/** 当前是不是浏览器（uni-app H5 也算）。 */
export const isBrowser = () => hasDom() && typeof fetch === 'function' && typeof WebSocket === 'function'

export function browserPlatform(): ImPlatform {
  return {
    suspends: false,
    WebSocket: WebSocket as unknown as new (url: string) => SocketLike,

    async request({ method, url, headers, body, timeoutMs }) {
      const abort = new AbortController()
      const timer = setTimeout(() => abort.abort(), timeoutMs)
      try {
        const res = await fetch(url, { method, headers, body, signal: abort.signal })
        return { status: res.status, text: await res.text() }
      } catch (e) {
        throw network(abort.signal.aborted ? `请求超时（${timeoutMs / 1000} 秒）` : String((e as Error)?.message ?? e))
      } finally {
        clearTimeout(timer)
      }
    },

    async upload({ url, headers, fields, file, filename, timeoutMs, onProgress }) {
      const form = new FormData()
      for (const k of Object.keys(fields)) form.append(k, fields[k])
      form.append('file', await toBlob(file), filename)
      // fetch 没有上传进度
      return new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest()
        xhr.open('POST', url)
        for (const k of Object.keys(headers)) xhr.setRequestHeader(k, headers[k])
        xhr.timeout = timeoutMs
        if (onProgress) xhr.upload.onprogress = e => e.lengthComputable && onProgress(e.loaded, e.total)
        xhr.onload = () => resolve({ status: xhr.status, text: xhr.responseText })
        xhr.onerror = () => reject(network('上传失败'))
        xhr.onabort = xhr.onerror
        xhr.ontimeout = () => reject(network(`上传超时（${timeoutMs / 1000} 秒）`))
        xhr.send(form)
      })
    },

    checkFile(f) {
      if (isBlob(f) || /^(blob|data):/.test(f?.path ?? '')) return
      throw new TypeError('浏览器里附件请传 Blob / File，或 blob:、data: 路径')
    },

    async imageSize(f) {
      const url = isBlob(f) ? URL.createObjectURL(f) : f.path
      try {
        return await new Promise<{ width: number; height: number }>((resolve, reject) => {
          const img = new Image()
          img.onload = () => resolve({ width: img.naturalWidth, height: img.naturalHeight })
          img.onerror = () => reject(new Error('图片解码失败'))
          img.src = url
        })
      } finally {
        if (isBlob(f)) URL.revokeObjectURL(url)
      }
    },

    onVisibility(cb) {
      if (!hasDom()) return () => {}
      const fn = () => cb(document.visibilityState === 'visible')
      document.addEventListener('visibilitychange', fn)
      return () => document.removeEventListener('visibilitychange', fn)
    },

    onNetwork(cb) {
      if (typeof addEventListener !== 'function') return () => {}
      const on = () => cb({ online: true })
      const off = () => cb({ online: false })
      addEventListener('online', on)
      addEventListener('offline', off)
      return () => {
        removeEventListener('online', on)
        removeEventListener('offline', off)
      }
    },
  }
}
