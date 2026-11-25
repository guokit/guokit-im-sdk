const CST = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/

/** 服务端时间（`YYYY-MM-DD HH:mm:ss`，固定东八区）→ 毫秒时间戳。不能用 Date.parse：各平台对无时区字符串解释不一。 */
export function parseCst(s: string): number {
  const m = CST.exec(s)
  if (!m) throw new RangeError(`时间格式应为 YYYY-MM-DD HH:mm:ss：${s}`)
  return Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4] - 8, +m[5], +m[6])
}
