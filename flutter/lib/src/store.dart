/// 本地存储接口（spec §3.4）与两种实现共用的合并规则。
///
/// 实现：`store_sqlite.dart`（iOS / Android，每用户一个库文件）、`store_memory.dart`（Web，只在内存）。
/// 按平台选哪个见 `store_factory.dart`。
///
/// 约定：
/// - 「已确认消息」= 有 `conversationId` 与 `seq` 的消息（服务端接收过）；
///   「未确认消息」= 本设备发出、`seq` 为空的 sending / failed / rejected 消息。
/// - 除 [ImStore.open] / [ImStore.deleteAll] 外，所有方法都要求已 open，否则抛 [StateError]。
library;

import 'dart:math' as math;

import 'models.dart';

/// [ImStore.upsertMessage] 的结果。
///
/// - [message]：合并后实际落库的那条。
/// - [inserted]：true 表示本地原来没有（按 id、按 `(from, clientMsgId)` 都没匹配上）。
///   同步层处理推送时据此决定发不发 `onNewMessage`：本设备待确认的消息被推送合并时为 false，
///   HTTP 先到、推送后到时推送那次也为 false。补拉 / 翻历史入库的不应发 `onNewMessage`，由调用方自己区分。
typedef ImUpsertResult = ({ImMessage message, bool inserted});

abstract class ImStore {
  /// 当前打开的用户；未打开为 null。
  String? get userId;

  /// 打开 [userId] 的本地库（已打开别的用户时先关掉）。
  Future<void> open(String userId);

  /// 关闭当前库，数据保留。未打开时什么也不做。
  Future<void> close();

  /// 删除 [userId] 的全部本地数据（登出 `clearCache: true` 用）。是当前打开的用户时先关闭。
  Future<void> deleteAll(String userId);

  // ---------------- 会话 ----------------

  /// 写入服务端会话列表的一页。已存在的会话按下面规则合并（[mergeConversation]）：
  /// peer / type / 置顶 / 免打扰取服务端；`maxSeq`、`readSeq`、`clearSeq` 取两边较大值（本地可能已被推送推进）；
  /// 服务端 `maxSeq` 不小于本地时 `lastMessage` / `lastMsgAt` 取服务端，清空范围内的预览置 null；
  /// 同一条消息本地预览已是撤回的，不退回旧预览。`peerReadSeq` 两边都有取较大值，服务端没给取 null。
  /// `syncedSeq` 不动，新会话为 0。`clearSeq` 变大时只改这一行，旧消息由调用方先调 [clearMessages] 清掉。
  Future<void> upsertConversations(List<ImConversation> list);

  Future<ImConversation?> getConversation(int conversationId);

  /// 按对方 user_id 查会话（单聊每对用户只有一条会话）。
  Future<ImConversation?> conversationByPeer(String peerId);

  /// 全部会话：置顶在前，按 `pinnedAt` 倒序；其余（及同时置顶的）按 `lastMsgAt` 倒序，再按 id 倒序。
  Future<List<ImConversation>> listConversations();

  /// 已读位置只进不退。返回更新后的会话；会话不存在返回 null。
  Future<ImConversation?> setReadSeq(int conversationId, int readSeq);

  /// 所有会话 `readSeq = maxSeq`（`read_all` 推送 / 一键清未读）。
  Future<void> markAllRead();

  /// 各**非免打扰**会话 `maxSeq − readSeq`（不小于 0）之和。
  Future<int> totalUnread();

  /// 清空到 [clearSeq]：删掉该会话本地 `seq <= clearSeq` 的消息，`clearSeq` / `maxSeq` / `readSeq` / `syncedSeq`
  /// 都不低于它，落在清空范围内的会话预览置 null（规则见 [clearedConversation]）。未确认消息不动。
  /// 会话不存在、或 [clearSeq] 不比本地大时什么也不做。须是原子的：清到一半会留下再也没人清的旧消息。
  Future<void> clearMessages(int conversationId, int clearSeq);

  /// 删除会话行及其全部消息，含发给该会话对方的未确认消息。会话不存在时也删掉该会话的消息。
  /// 消息必须一起删：否则会话因新消息重新出现后，旧消息会跟着显示出来。
  Future<void> deleteConversation(int conversationId);

  /// 会话设置增量补齐的游标（`GET /conversations/changes` 的 `next_cursor`），没存过为 null。
  Future<String?> changesCursor();

  Future<void> setChangesCursor(String cursor);

  /// 撤回增量补齐的游标（`GET /recalls` 的 `next_cursor`），没存过为 null。
  Future<String?> recallsCursor();

  Future<void> setRecallsCursor(String cursor);

  /// 对方已读位置，只进不退（本地为 null 时直接写入）。返回更新后的会话；会话不存在返回 null。
  Future<ImConversation?> setPeerReadSeq(int conversationId, int peerReadSeq);

  /// 本地已连续持有到的 seq；0 表示从没拉过这个会话的消息（或会话不存在）。
  Future<int> syncedSeq(int conversationId);

  /// 设置 `syncedSeq`（如打开会话拉完最新一页后设为该页最大 seq），随后自动沿本地已有的连续消息往后推进。
  /// 返回推进后的值。会话不存在时什么也不做，返回 0。
  ///
  /// 另外 [upsertMessage] 入库 `seq == syncedSeq + 1` 的消息时也会自动推进（`syncedSeq > 0` 时），
  /// 所以对账补拉、推送顺序到达都不必手动维护；只有「从 0 开始」与「明确知道断档」时才需要调本方法。
  Future<int> setSyncedSeq(int conversationId, int seq);

  // ---------------- 消息 ----------------

  /// 写入一条消息并返回合并结果。匹配顺序：先按 `id`（非空时），再按 `(from, clientMsgId)`，都没有才插入。
  /// 合并规则见 [mergeMessage]，要点：
  /// - 服务端版本（有 id）覆盖本地字段，`status` 变 sent、错误码清空，但保留本地 `localPath`；
  ///   `to` 为空串时保留本地的 `to`；`urlFetchedAt` 为空时保留本地的；
  /// - 撤回不可逆：本地已撤回的不会被旧版本覆盖（翻历史、迟到的发送响应都会带旧版本来）；变成撤回时清空 `localPath`、`urlFetchedAt`；
  /// - 已确认（sent）的消息不会被本地版本（无 id）降级——推送先到、HTTP 后超时也不会把它标成 failed。
  ///
  /// 会话存在且 `seq <= clearSeq` 的消息（清空前发出、清空后才到）不入库，已有的本地版本一并删掉，
  /// 返回 `inserted: false`。
  ///
  /// 已确认消息入库后的副作用（[bumpConversation]）：
  /// - 会话存在：`seq > maxSeq` 时推进 `maxSeq` / `lastMessage` / `lastMsgAt`；撤回的正是 `lastMessage` 那条时换预览；本人发的消息把 `readSeq` 推到该条；
  /// - 会话不存在：按对方 id 建一条占位会话（peer 昵称头像为空串，等下次会话列表对齐），对方 id 为空串时不建；
  /// - `syncedSeq > 0` 且 `seq == syncedSeq + 1` 时推进 `syncedSeq`。
  ///
  /// 发送层的用法：插入 sending → 失败时 `upsertMessage(m.copyWith(status: failed, errorCode: …))`
  /// → 成功时 `upsertMessage(ImMessage.fromServer(…))`；重拉图片链接后同样直接 upsert 服务端版本。
  Future<ImUpsertResult> upsertMessage(ImMessage message);

  /// 批量 [upsertMessage]（sqlite 在一个事务里），结果与入参一一对应。补拉 / 翻历史用。
  Future<List<ImUpsertResult>> upsertMessages(List<ImMessage> messages);

  Future<ImMessage?> getMessageById(int id);

  Future<ImMessage?> getMessageByClientMsgId(String from, String clientMsgId);

  /// 已确认消息：`seq < beforeSeq`（不传则不限）的最近 [limit] 条，按 seq 升序。不含未确认消息。
  Future<List<ImMessage>> messages(
    int conversationId, {
    int? beforeSeq,
    int limit = 30,
  });

  /// 本地已有的最大 seq，没有为 0。
  Future<int> maxLocalSeq(int conversationId);

  /// 本地是否完整持有 `[fromSeq, toSeq]` 闭区间内的每一条消息。`fromSeq > toSeq` 时为 true。
  Future<bool> isContiguous(int conversationId, int fromSeq, int toSeq);

  /// 发给 [peerId] 的未确认消息（sending / failed / rejected），按本地插入顺序。
  /// 首条消息发送成功前还没有会话 id，所以按对方 id 查，不按会话查。
  Future<List<ImMessage>> unconfirmedMessages(String peerId);
}

// ---------------- 两种实现共用的规则 ----------------

/// 已确认：有会话 id 与 seq。
bool isConfirmed(ImMessage m) => m.conversationId != null && m.seq != null;

/// 消息合并规则，见 [ImStore.upsertMessage]。
ImMessage mergeMessage(ImMessage existing, ImMessage incoming) {
  if (existing.status == ImMessageStatus.sent && incoming.id == null) {
    return existing;
  }
  final to = incoming.to.isEmpty ? existing.to : incoming.to;
  if (existing.isRecalled && !incoming.isRecalled) {
    return existing.copyWith(to: existing.to.isEmpty ? to : existing.to);
  }
  final recalled = incoming.isRecalled;
  return incoming.copyWith(
    to: to,
    localPath: recalled ? null : incoming.localPath ?? existing.localPath,
    urlFetchedAt: recalled
        ? null
        : incoming.urlFetchedAt ?? existing.urlFetchedAt,
    senderRole: incoming.senderRole ?? existing.senderRole,
  );
}

/// 会话合并规则，见 [ImStore.upsertConversations]。
ImConversation mergeConversation(
  ImConversation? local,
  ImConversation incoming,
) {
  if (local == null) return incoming;
  final newer = incoming.maxSeq >= local.maxSeq;
  final clearSeq = math.max(local.clearSeq, incoming.clearSeq);
  var last = newer
      ? (incoming.lastMessage ?? local.lastMessage)
      : local.lastMessage;
  final mine = local.lastMessage;
  if (mine != null &&
      mine.type == 'recalled' &&
      last != null &&
      last.seq == mine.seq) {
    last = mine; // 撤回不可逆：在途的旧列表不能把原文预览写回来
  }
  final peerRead = incoming.peerReadSeq;
  return incoming.copyWith(
    maxSeq: math.max(local.maxSeq, incoming.maxSeq),
    readSeq: math.max(local.readSeq, incoming.readSeq),
    clearSeq: clearSeq,
    // 清空后服务端返回 null，不能退回本地的旧预览。
    lastMessage: last != null && last.seq > clearSeq ? last : null,
    lastMsgAt: newer ? incoming.lastMsgAt : local.lastMsgAt,
    peerReadSeq: peerRead == null
        ? null
        : math.max(peerRead, local.peerReadSeq ?? 0),
  );
}

/// 清空到 [clearSeq] 对会话行的影响，见 [ImStore.clearMessages]。
ImConversation clearedConversation(ImConversation c, int clearSeq) {
  final last = c.lastMessage;
  return c.copyWith(
    clearSeq: clearSeq,
    maxSeq: math.max(c.maxSeq, clearSeq),
    readSeq: math.max(c.readSeq, clearSeq),
    lastMessage: last != null && last.seq > clearSeq ? last : null,
  );
}

/// 会话预览文字，口径同服务端：text 前 50 字，image `[图片]`，voice `[语音]`，
/// file `[文件] 名字`（共 50 字以内），video `[视频]`，location `[位置]`，custom 取 desc。
String previewOf(ImMessage m) {
  switch (m.type) {
    case 'text':
      return _first50((m.content['text'] as String?) ?? '');
    case 'image':
      return '[图片]';
    case 'voice':
      return '[语音]';
    case 'file':
      return _first50('[文件] ${(m.content['name'] as String?) ?? ''}');
    case 'video':
      return '[视频]';
    case 'recalled':
      return '[消息已撤回]';
    case 'location':
      return '[位置]';
    case 'custom':
      return (m.content['desc'] as String?) ?? '';
    default:
      return '';
  }
}

String _first50(String s) => String.fromCharCodes(s.runes.take(50));

/// 已确认消息对会话的影响，见 [ImStore.upsertMessage]。
///
/// [conv] 为 null 时返回占位会话（对方 id 为空串则返回 null）；无变化时原样返回 [conv]。
ImConversation? bumpConversation(ImConversation? conv, ImMessage m) {
  final seq = m.seq!;
  final preview = ImMessagePreview(
    seq: seq,
    from: m.from,
    type: m.type,
    preview: previewOf(m),
    createdAt: m.createdAt,
  );
  if (conv == null) {
    final peerId = m.isSelf ? m.to : m.from;
    if (peerId.isEmpty) return null;
    return ImConversation(
      id: m.conversationId!,
      type: peerId == '@cs' ? 'service' : 'c2c',
      peer: ImPeer(userId: peerId, nickname: '', avatarUrl: ''),
      lastMessage: preview,
      maxSeq: seq,
      // 别人发来的只算这一条未读；本人发的不计未读。
      readSeq: m.isSelf ? seq : seq - 1,
      lastMsgAt: m.createdAt,
    );
  }
  var c = conv;
  if (seq > c.maxSeq) {
    c = c.copyWith(maxSeq: seq, lastMessage: preview, lastMsgAt: m.createdAt);
  }
  if (m.isRecalled &&
      c.lastMessage?.seq == seq &&
      c.lastMessage?.type != 'recalled') {
    c = c.copyWith(lastMessage: preview);
  }
  if (m.isSelf && seq > c.readSeq) c = c.copyWith(readSeq: seq);
  return c;
}

/// 从 [synced] 起沿升序的 [seqsAfter]（都大于 synced）找连续段的末尾。
int advanceSynced(int synced, Iterable<int> seqsAfter) {
  var s = synced;
  for (final q in seqsAfter) {
    if (q == s + 1) {
      s = q;
    } else if (q > s + 1) {
      break;
    }
  }
  return s;
}
