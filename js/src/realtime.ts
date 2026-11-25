import { Centrifuge } from 'centrifuge'
import type { ImPlatform } from './platform/types.js'

/** 令牌无效：换令牌后重连。 */
export const CODE_TOKEN_INVALID = 3500
/** 被封禁或踢下线：当登出。 */
export const CODE_KICKED = 3503

export interface RealtimeHooks {
  onConnecting(): void
  onConnected(): void
  /** 已断开且不会自动重连。 */
  onDisconnected(code: number): void
  onPublication(data: any): void
}

/** 长连接。一次登录一个实例，close 后不再用。 */
export interface Realtime {
  connect(token: string): void
  /** 通知网络变化：offline 立刻丢掉现有连接，online 在连接中时立刻重连、已连上时是空操作。 */
  network(event: 'offline' | 'online'): void
  close(): void
}

export type RealtimeFactory = (url: string, platform: ImPlatform, hooks: RealtimeHooks) => Realtime

export function webSocketUrl(baseUrl: string): string {
  return baseUrl.replace(/^http/, 'ws') + '/api/im/v1/connect/websocket'
}

/** centrifuge 只用 EventTarget 的两个方法；小程序没有 EventTarget。 */
class Target {
  private fns = new Map<string, Set<() => void>>()

  addEventListener(type: string, fn: () => void): void {
    let set = this.fns.get(type)
    if (!set) this.fns.set(type, (set = new Set()))
    set.add(fn)
  }

  removeEventListener(type: string, fn: () => void): void {
    this.fns.get(type)?.delete(fn)
  }

  fire(type: string): void {
    for (const fn of [...(this.fns.get(type) ?? [])]) fn()
  }
}

export const createRealtime: RealtimeFactory = (url, platform, hooks) => {
  const target = new Target()
  const client = new Centrifuge(url, {
    websocket: platform.WebSocket,
    networkEventTarget: target as unknown as EventTarget,
    // 小程序没有 pagehide / pageshow；浏览器的 bfcache 由 centrifuge 自己处理
    pageEventTarget: platform.suspends ? (new Target() as unknown as EventTarget) : null,
  })
  let terminal: number | null = null
  // 监听器里抛错会让 centrifuge 以 badProtocol 断开且不重连，所以每个都接住
  const safe = <A>(f: (a: A) => void) => (a: A) => {
    try {
      f(a)
    } catch (e) {
      console.error('[guokit-im]', e)
    }
  }
  const onConnecting = safe((ctx: { code: number }) => {
    // 断开码该终止却被当成可重连（平台没给 reason）：自己断开，按终止处理
    if (ctx.code === CODE_TOKEN_INVALID || ctx.code === CODE_KICKED) {
      terminal = ctx.code
      void Promise.resolve().then(() => client.disconnect())
      return
    }
    hooks.onConnecting()
  })
  const onConnected = safe(() => hooks.onConnected())
  const onDisconnected = safe((ctx: { code: number }) => {
    const code = terminal ?? ctx.code
    terminal = null
    hooks.onDisconnected(code)
  })
  const onPublication = safe((ctx: { data: any }) => hooks.onPublication(ctx.data))
  let warned = false
  const onError = safe((ctx: any) => {
    // 握手被拒（如 Origin 不在白名单）没有断开码，只会一直连不上，留一条线索
    if (!warned) console.warn('[guokit-im] 长连接出错，将自动重试', ctx?.error?.message ?? ctx)
    warned = true
  })
  client.on('connecting', onConnecting)
  client.on('connected', onConnected)
  client.on('disconnected', onDisconnected)
  client.on('publication', onPublication)
  client.on('error', onError)

  return {
    connect(token) {
      client.setToken(token)
      client.connect()
    },
    network: e => target.fire(e),
    close() {
      // 先摘自己的监听，断开产生的 disconnected 才不会进门面。不能 removeAllListeners：会摘掉它内部的兜底
      client.off('connecting', onConnecting)
      client.off('connected', onConnected)
      client.off('disconnected', onDisconnected)
      client.off('publication', onPublication)
      client.off('error', onError)
      client.disconnect()
    },
  }
}
