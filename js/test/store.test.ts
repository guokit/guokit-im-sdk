import { beforeEach, expect, test } from 'vitest'
import { conversationFromServer, makeMessage, messageFromServer, type ImMessage } from '../src/models.js'
import { Store } from '../src/store.js'

export const conv = (over: object = {}) => conversationFromServer({
  conversation_id: 1, type: 'c2c', peer: { user_id: 'u2' }, last_message: null,
  max_seq: 0, read_seq: 0, last_msg_at: '2026-11-20 10:00:00', ...over,
})
export const msg = (seq: number, over: object = {}) => messageFromServer({
  id: 100 + seq, conversation_id: 1, seq, from: 'u2', type: 'text', content: { text: `m${seq}` },
  client_msg_id: `c${seq}`, created_at: '2026-11-20 10:00:00', ...over,
}, 'u1', 'u2')
const recalled = (seq: number, over: object = {}) => msg(seq, { type: 'recalled', content: { by: 'sender' }, ...over })
const pending = (cid: string, over: Partial<ImMessage> = {}) => makeMessage({
  ...msg(1), id: null, seq: null, clientMsgId: cid, from: 'u1', to: 'u2', isSelf: true, status: 'sending', ...over,
})

let s: Store
beforeEach(() => {
  s = new Store()
})

test('HTTP 与推送谁先到都只有一条，已确认的不被失败版本降级', () => {
  s.upsertConversations([conv()])
  const local = pending('c1', { localPath: '/a' })
  expect(s.upsertMessage(local).inserted).toBe(true)
  expect(s.upsertMessage(msg(1, { from: 'u1' })).inserted).toBe(false)
  expect(s.upsertMessage(msg(1, { from: 'u1' })).inserted).toBe(false)
  s.upsertMessage(makeMessage({ ...local, status: 'failed', errorCode: 'NETWORK' }))
  expect(s.messages(1, 30)).toHaveLength(1)
  expect(s.messages(1, 30)[0]).toMatchObject({ status: 'sent', seq: 1, localPath: '/a' })
  expect(s.unconfirmed('u2')).toEqual([])
})

test('撤回不被旧版本覆盖，预览跟着换，旧列表写不回原文', () => {
  s.upsertConversations([conv()])
  s.upsertMessage(msg(1))
  s.upsertMessage(recalled(1))
  s.upsertMessage(msg(1))
  expect(s.messageById(101)).toMatchObject({ isRecalled: true, urlFetchedAt: null })
  expect(s.conversation(1)!.lastMessage).toMatchObject({ type: 'recalled', preview: '[消息已撤回]' })
  s.upsertConversations([conv({ max_seq: 1, last_message: { seq: 1, from: 'u2', type: 'text', preview: 'm1', created_at: '2026-11-20 10:00:00' } })])
  expect(s.conversation(1)!.lastMessage!.type).toBe('recalled')
})

test('未读：别人发的计，自己发的推进已读，免打扰不进总数', () => {
  s.upsertConversations([conv(), conv({ conversation_id: 2, peer: { user_id: 'u3' }, max_seq: 5, muted: true })])
  s.upsertMessage(msg(1))
  s.upsertMessage(msg(2))
  expect([s.conversation(1)!.unread, s.totalUnread()]).toEqual([2, 2])
  s.upsertMessage(msg(3, { from: 'u1' }))
  expect(s.totalUnread()).toBe(0)
  s.setReadSeq(1, 1)
  expect(s.conversation(1)!.readSeq).toBe(3)
})

test('清空：旧消息删掉、预览置空、迟到的旧消息不回来；先于会话到的也清', () => {
  s.upsertConversations([conv({ max_seq: 3 })])
  for (const i of [1, 2, 3]) s.upsertMessage(msg(i))
  s.clearMessages(1, 3)
  expect(s.upsertMessage(msg(2)).inserted).toBe(false)
  expect(s.messages(1, 30)).toEqual([])
  expect(s.conversation(1)).toMatchObject({ clearSeq: 3, unread: 0, lastMessage: null })
  const t = new Store()
  t.upsertMessage(msg(2))
  t.upsertConversations([conv({ max_seq: 4, clear_seq: 3 })])
  expect(t.messages(1, 30)).toEqual([])
})

test('删除会话连未确认消息一起删；没有 peer 的会话不误删、不误中', () => {
  s.upsertConversations([conv(), conv({ conversation_id: 9, type: 'group', peer: undefined })])
  s.upsertMessage(msg(1))
  s.upsertMessage(pending('p1'))
  s.deleteConversation(9)
  expect(s.unconfirmed('u2')).toHaveLength(1)
  s.deleteConversation(1)
  expect([s.unconfirmed('u2').length, s.conversations().length, s.conversationByPeer('u2')]).toEqual([0, 0, null])
})

test('syncedSeq 沿连续消息推进，断档停住', () => {
  s.upsertConversations([conv()])
  s.upsertMessage(msg(1))
  s.setSyncedSeq(1, 1)
  s.upsertMessage(msg(3))
  expect(s.syncedSeq(1)).toBe(1)
  s.upsertMessage(msg(2))
  expect(s.syncedSeq(1)).toBe(3)
})

test('排序：置顶在前按置顶时间，其余按最后消息时间', () => {
  s.upsertConversations([
    conv({ conversation_id: 1 }),
    conv({ conversation_id: 2, last_msg_at: '2026-11-20 11:00:00' }),
    conv({ conversation_id: 3, pinned_at: '2026-11-19 10:00:00' }),
    conv({ conversation_id: 4, pinned_at: '2026-11-19 11:00:00' }),
  ])
  expect(s.conversations().map(c => c.id)).toEqual([4, 3, 2, 1])
})
