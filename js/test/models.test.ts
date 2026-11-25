import { expect, test, vi } from 'vitest'
import { Emitter } from '../src/emitter.js'
import { ImKickedOutError, isKickedOut } from '../src/errors.js'
import { conversationFromServer, makeMessage, messageCard, messageFromServer, previewOf } from '../src/models.js'
import { parseCst } from '../src/time.js'

const raw = (over: object = {}) => ({
  id: 1024, conversation_id: 12, seq: 37, from: 'u2', type: 'text', content: { text: '你好' },
  client_msg_id: 'c1', created_at: '2026-11-20 10:00:00', ...over,
})

test('东八区时间，跨日借位；格式不对抛错', () => {
  expect(parseCst('2026-11-20 03:00:00')).toBe(Date.UTC(2026, 10, 19, 19))
  expect(() => parseCst('2026-11-20T10:00:00Z')).toThrow(RangeError)
})

test('消息推导 to / isSelf，派生字段', () => {
  expect(messageFromServer(raw(), 'u1', 'u2')).toMatchObject({ to: 'u1', isSelf: false, status: 'sent' })
  expect(messageFromServer(raw(), 'u2', 'u9')).toMatchObject({ to: 'u9', isSelf: true })
  expect(messageFromServer(raw({ from: '@cs', sender_role: 'bot' }), 'u1').isBot).toBe(true)
  expect(messageFromServer(raw({ type: 'recalled', content: { by: 'server' } }), 'u1'))
    .toMatchObject({ isRecalled: true, recalledBy: 'server' })
})

test('没有 peer 的会话照常解析（将来的群），客服会话带主体标识', () => {
  const j = { conversation_id: 5, type: 'group', last_message: null, max_seq: 9, read_seq: 4, last_msg_at: '2026-11-20 10:00:00' }
  expect(conversationFromServer(j)).toMatchObject({ id: 5, peer: null, serviceId: null, unread: 5, pinnedAt: null, peerReadSeq: null })
  const cs = conversationFromServer({ ...j, type: 'service', peer: { user_id: '@cs:s1' }, pinned_at: '2026-11-20 10:00:00' })
  expect(cs).toMatchObject({ serviceId: 's1', isService: true, pinned: true, peer: { nickname: '', avatarUrl: '' } })
})

test('预览：text 与 file 截 50 码点，custom 不截', () => {
  const m = (type: string, content: object) => makeMessage({ ...messageFromServer(raw(), 'u1'), type, content })
  expect(previewOf(m('text', { text: '😀'.repeat(60) }))).toBe('😀'.repeat(50))
  expect(previewOf(m('file', { name: '长'.repeat(60) }))).toBe('[文件] ' + '长'.repeat(45))
  expect(previewOf(m('custom', { desc: '长'.repeat(60) }))).toHaveLength(60)
  expect(previewOf(m('新类型', {}))).toBe('')
})

test('业务卡片：坏字段按缺省，缺 title 为 null', () => {
  const fields = [{ label: '金额', value: '¥99' }, { label: '', value: 'x' }, { label: '数量', value: 2 }, null]
  expect(messageCard({ type: 'custom', content: { data: { im_card: { title: '订单', image: 123, fields } } } }))
    .toMatchObject({ title: '订单', image: null, fields: [{ label: '金额', value: '¥99' }] })
  expect(messageCard({ type: 'custom', content: { data: { im_card: { kind: 'order' } } } })).toBeNull()
})

test('事件下一拍投递、会话作废后不送、监听器抛错不影响别人', async () => {
  const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
  const e = new Emitter<{ a: number }>()
  const got: number[] = []
  let alive = true
  e.on('a', () => { throw new Error('x') })
  const off = e.on('a', v => got.push(v))
  e.emit('a', 1)
  expect(got).toEqual([])
  e.emit('a', 2, () => alive)
  alive = false
  await Promise.resolve()
  expect(got).toEqual([1])
  off()
  e.emit('a', 3)
  await Promise.resolve()
  expect(got).toEqual([1])
  spy.mockRestore()
})

test('踢下线按 name 认，不只靠 instanceof', () => {
  expect(isKickedOut(new ImKickedOutError())).toBe(true)
  expect(isKickedOut({ name: 'ImKickedOutError' })).toBe(true)
  expect(isKickedOut(new Error('x'))).toBe(false)
})
