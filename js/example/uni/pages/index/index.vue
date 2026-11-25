<script setup>
import { computed, nextTick, ref } from 'vue'
import { GuokitIm, uniPlatform } from '../../libs/guokit-im.esm.js'

// 真实项目里令牌由自家后端签发；这里为了能独立运行，手工填一个已签好的。
const form = ref(uni.getStorageSync('im-example') || { baseUrl: '', userId: '', token: '', peer: '' })
const state = ref('disconnected')
const total = ref(0)
const convs = ref([])
const peer = ref('')
const list = ref([])
const text = ref('')
const typing = ref(false)
const logs = ref([])
const bottom = ref('')
let im = null

const log = (...a) => logs.value = [...logs.value.slice(-30), `${new Date().toLocaleTimeString()} ${a.join(' ')}`]
const conv = computed(() => convs.value.find(c => c.peer && c.peer.userId === peer.value))
const recalled = m => (m.isSelf ? '你' : '对方') + '撤回了一条消息'
const urls = ref({})

async function login() {
  uni.setStorageSync('im-example', form.value)
  const { baseUrl, userId, token } = form.value
  im = new GuokitIm({
    baseUrl,
    tokenProvider: async () => ({ token, expires_at: '2099-01-01 00:00:00' }),
    platform: uniPlatform(uni),
  })
  im.on('connection', s => { state.value = s; log('连接', s) })
  im.on('totalUnread', n => total.value = n)
  // 首条消息发成功后会话才出现，这时要把聊天页从「未确认消息」换成会话消息
  im.on('conversations', l => { const had = !!conv.value; convs.value = l; if (!had && conv.value) open() })
  im.on('newMessage', m => { log('新消息', m.type, m.seq); refresh(); if (m.conversationId === conv.value?.id) im.markRead(m.conversationId) })
  im.on('messageUpdated', m => { if (m.status !== 'sent') log(m.type, m.status, m.errorCode || '', m.errorMessage || ''); refresh() })
  im.on('kickedOut', () => { log('被踢下线'); logout() })
  im.on('typing', t => { if (t.conversationId === conv.value?.id) typing.value = t.active })
  im.on('sendProgress', p => log('上传', Math.round(p.sent / p.total * 100) + '%'))
  await im.login(userId)
  peer.value = form.value.peer
  setTimeout(open, 800)
}

function logout() {
  im.logout()
  im = null
  list.value = []
  peer.value = ''
}

async function open(userId) {
  if (typeof userId === 'string') peer.value = userId
  await refresh()
  if (conv.value) im.markRead(conv.value.id).catch(e => log('标已读', e.message))
}

async function refresh() {
  if (!im || !peer.value) return
  try {
    list.value = conv.value ? await im.messages(conv.value.id) : im.pendingTo(peer.value)
    for (const m of list.value) if (m.type === 'image' && !m.isRecalled) urls.value[m.clientMsgId] = await im.imageUrl(m)
    await nextTick()
    bottom.value = ''
    await nextTick()
    bottom.value = 'bottom'
  } catch (e) {
    log('拉消息', e.message)
  }
}

function send() {
  const t = text.value.trim()
  if (!t) return
  text.value = ''
  im.sendText(peer.value, t)
}

function onInput() {
  if (conv.value) im.sendTyping(conv.value.id)
}

function image() {
  uni.chooseImage({ count: 1, sizeType: ['compressed'], success: r => im.sendImage(peer.value, { path: r.tempFilePaths[0] }) })
}

function file() {
  // #ifdef MP-WEIXIN
  uni.chooseMessageFile({ count: 1, type: 'file', success: r => { const f = r.tempFiles[0]; im.sendFile(peer.value, { path: f.path, size: f.size }, { name: f.name }) } })
  // #endif
  // #ifdef H5
  uni.chooseFile({ count: 1, success: r => im.sendFile(peer.value, r.tempFiles[0]) })
  // #endif
}

function press(m) {
  if (m.status === 'failed') return im.resend(m)
  if (m.isSelf && m.status === 'sent' && !m.isRecalled) {
    uni.showModal({ title: '撤回这条消息？', success: r => r.confirm && im.recall(m).catch(e => log('撤回', e.message)) })
  }
}
</script>

<template>
  <view class="page">
    <view v-if="!peer && state === 'disconnected'">
      <input v-model="form.baseUrl" placeholder="IM 地址 https://…" />
      <input v-model="form.userId" placeholder="我的 user_id" />
      <input v-model="form.token" maxlength="-1" placeholder="令牌" />
      <input v-model="form.peer" placeholder="对方 user_id" />
      <button type="primary" @click="login">登录</button>
    </view>
    <template v-else>
      <view class="bar">{{ state }} · 未读 {{ total }} · 对方 {{ peer }}<text v-if="typing"> 正在输入…</text><text class="link" @click="logout">登出</text></view>
      <scroll-view scroll-x class="convs">
        <text v-for="c in convs" :key="c.id" class="conv" @click="c.peer && open(c.peer.userId)">{{ c.peer ? c.peer.nickname || c.peer.userId : c.type }}({{ c.unread }})</text>
      </scroll-view>
      <scroll-view scroll-y class="list" :scroll-into-view="bottom">
        <view v-for="m in list" :key="m.clientMsgId" :class="['row', m.isSelf ? 'self' : '']" @longpress="press(m)">
          <image v-if="m.type === 'image'" class="img" mode="aspectFit" :src="m.localPath || urls[m.clientMsgId]" />
          <text v-else class="bubble">{{ m.isRecalled ? recalled(m) : m.type === 'text' ? m.content.text : `[${m.type}] ${m.fileName || ''}` }}</text>
          <text class="tip">{{ m.status === 'sent' ? (m.isSelf && conv && conv.peerReadSeq !== null ? (m.seq <= conv.peerReadSeq ? '已读' : '未读') : '') : m.status }}</text>
        </view>
        <view id="bottom" />
      </scroll-view>
      <view class="send">
        <input v-model="text" class="text" placeholder="说点什么" @input="onInput" @confirm="send" />
        <button size="mini" @click="send">发送</button><button size="mini" @click="image">图</button><button size="mini" @click="file">文件</button>
      </view>
    </template>
    <scroll-view scroll-y class="logs"><view v-for="(l, i) in logs" :key="i">{{ l }}</view></scroll-view>
  </view>
</template>

<style>
.page { display: flex; flex-direction: column; height: 100vh; padding: 16rpx; box-sizing: border-box; font-size: 28rpx; }
input { border: 1px solid #ddd; padding: 12rpx; margin: 8rpx 0; }
.bar { padding: 8rpx 0; }
.link { color: #06c; margin-left: 24rpx; }
.convs { white-space: nowrap; border-bottom: 1px solid #eee; }
.conv { display: inline-block; padding: 12rpx 20rpx; color: #06c; }
.list { flex: 1; height: 0; }
.row { display: flex; align-items: flex-end; margin: 12rpx 0; }
.self { flex-direction: row-reverse; }
.bubble { background: #f2f3f5; padding: 14rpx 20rpx; border-radius: 12rpx; max-width: 70%; word-break: break-all; }
.self .bubble { background: #cfe8ff; }
.img { width: 240rpx; height: 240rpx; background: #f2f3f5; }
.tip { color: #999; font-size: 22rpx; margin: 0 10rpx; }
.send { display: flex; align-items: center; }
.text { flex: 1; }
.logs { height: 180rpx; background: #fafafa; color: #666; font-size: 20rpx; }
</style>
