type Handler = (payload: any) => void

/**
 * 事件**下一拍**才投递：监听器里直接 logout() / login() 不会重入正在跑的流程。
 * `alive` 在投递那一刻再核一次，换号后不送旧账号的事件。
 */
export class Emitter<E> {
  private handlers = new Map<keyof E, Set<Handler>>()

  on<K extends keyof E>(event: K, fn: (payload: E[K]) => void): () => void {
    let set = this.handlers.get(event)
    if (!set) this.handlers.set(event, (set = new Set()))
    set.add(fn)
    return () => void set!.delete(fn)
  }

  emit<K extends keyof E>(event: K, payload: E[K], alive: () => boolean = () => true): void {
    void Promise.resolve().then(() => {
      // 每个监听器前都再核一次：前一个可能刚登出
      for (const fn of [...(this.handlers.get(event) ?? [])]) {
        if (!alive()) return
        try {
          fn(payload)
        } catch (e) {
          console.error(`[guokit-im] ${String(event)} 监听器抛错`, e)
        }
      }
    })
  }

  clear(): void {
    this.handlers.clear()
  }
}
