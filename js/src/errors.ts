/**
 * IM 接口调用失败。`code` 是服务端的字符串错误码，或 SDK 自己的：
 * `NETWORK`（没拿到 HTTP 响应，`httpStatus` 为 0）、`BAD_RESPONSE`（响应不是合法的响应包）。
 */
export class ImApiError extends Error {
  readonly name = 'ImApiError'
  constructor(readonly code: string, message: string, readonly httpStatus: number) {
    super(message)
  }

  /** 令牌缺失 / 过期 / 用户被封或被踢。 */
  get isTokenInvalid() {
    return this.code === 'IM_TOKEN_INVALID'
  }

  get isNetwork() {
    return this.code === 'NETWORK'
  }

  /** 稍后重试可能成功。跨域时「没装客服」这类错误也会是 NETWORK，不要据此自动循环重试。 */
  get isTemporary() {
    return this.isNetwork || this.httpStatus >= 500 || this.code === 'IM_RATE_LIMITED'
  }
}

/** 接入方的 `tokenProvider` 发现用户已封禁 / 已登出时抛它：SDK 发 `kickedOut` 并停止重连。 */
export class ImKickedOutError extends Error {
  readonly name = 'ImKickedOutError'
  constructor(message = '用户已被封禁或已登出') {
    super(message)
  }
}

/** 按 name 判断：同一页面可能有两份包，instanceof 会认不出。 */
export function isKickedOut(e: unknown): e is ImKickedOutError {
  return e instanceof ImKickedOutError || (e as { name?: string } | null)?.name === 'ImKickedOutError'
}

/** 内部：登录会话已作废（登出 / 换号），在途请求到此为止。 */
export class ClosedError extends Error {
  readonly name = 'ImClosedError'
  constructor() {
    super('已登出')
  }
}
