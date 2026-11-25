import type { ImToken } from './models.js'
import { parseCst } from './time.js'

/** 距过期不足这么久就换新，少吃一次 401。 */
const EXPIRY_MARGIN = 60_000
/** 小程序退后台时 provider 的请求可能被杀、再也不回来。 */
const PROVIDER_TIMEOUT = 20_000

/** 令牌管理：HTTP 的 401 与长连接的 3500 共用，并发换令牌只调一次 provider。一次登录一个实例。 */
export class TokenManager {
  private token: { value: string; expiresAt: number } | null = null
  private inflight: Promise<string> | null = null
  /** clear 时自增，让清理前发出的换新结果不再写回缓存。 */
  private generation = 0

  constructor(private provider: () => Promise<ImToken> | ImToken) {}

  get cached(): string | null {
    return this.token?.value ?? null
  }

  current(): Promise<string> {
    const t = this.token
    if (!this.inflight && t && t.expiresAt > Date.now() + EXPIRY_MARGIN) return Promise.resolve(t.value)
    return this.refresh()
  }

  /** `stale` 是刚被服务端判失效的令牌；缓存里已是别的令牌说明别人先换过了，直接用。 */
  refresh(stale?: string): Promise<string> {
    const t = this.token
    if (!this.inflight && stale !== undefined && t && t.value !== stale) return Promise.resolve(t.value)
    if (this.inflight) return this.inflight
    this.token = null
    const gen = this.generation
    const p: Promise<string> = withTimeout(Promise.resolve().then(this.provider)).then(r => {
      const next = { value: r.token, expiresAt: parseCst(r.expires_at) }
      if (typeof next.value !== 'string' || !next.value) throw new TypeError('tokenProvider 没有返回 token')
      if (gen === this.generation) this.token = next
      return next.value
    })
    this.inflight = p
    const done = () => {
      if (this.inflight === p) this.inflight = null
    }
    p.then(done, done)
    return p
  }

  clear(): void {
    this.generation++
    this.token = null
    this.inflight = null
  }
}

function withTimeout<T>(p: Promise<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('tokenProvider 20 秒没有返回')), PROVIDER_TIMEOUT)
    p.then(resolve, reject).then(() => clearTimeout(timer))
  })
}
