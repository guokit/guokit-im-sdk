/// 内存存储（Web 用）：不依赖 dart:io / sqflite，刷新页面即丢，登录后从服务端重拉。
///
/// 同一个实例内按用户分开保存，切换账号再切回来数据仍在；[deleteAll] 删掉该用户那份。
library;

import 'dart:math' as math;

import 'models.dart';
import 'store.dart';

class _Data {
  final Map<int, ImConversation> conversations = {};
  final Map<int, int> synced = {};
  String? changesCursor;
  String? recallsCursor;

  /// local_id → 消息，local_id 自增，即插入顺序。
  final Map<int, ImMessage> messages = {};
  final Map<int, int> byId = {};
  final Map<String, int> byCid = {};
  int nextLocalId = 1;

  void removeMessages(bool Function(ImMessage) test) {
    final ids = [
      for (final e in messages.entries)
        if (test(e.value)) e.key,
    ];
    for (final l in ids) {
      final m = messages.remove(l)!;
      if (m.id != null) byId.remove(m.id);
      byCid.remove(_cidKey(m.from, m.clientMsgId));
    }
  }
}

String _cidKey(String from, String cid) => '$from\u0000$cid';

class MemoryImStore implements ImStore {
  final Map<String, _Data> _users = {};
  String? _userId;

  @override
  String? get userId => _userId;

  _Data get _d {
    final u = _userId;
    if (u == null) throw StateError('ImStore 未打开');
    return _users[u]!;
  }

  @override
  Future<void> open(String userId) async {
    _userId = userId;
    _users.putIfAbsent(userId, _Data.new);
  }

  @override
  Future<void> close() async => _userId = null;

  @override
  Future<void> deleteAll(String userId) async {
    if (_userId == userId) _userId = null;
    _users.remove(userId);
  }

  // ---------------- 会话 ----------------

  @override
  Future<void> upsertConversations(List<ImConversation> list) async {
    final d = _d;
    for (final c in list) {
      d.conversations[c.id] = mergeConversation(d.conversations[c.id], c);
    }
  }

  @override
  Future<ImConversation?> getConversation(int conversationId) async =>
      _d.conversations[conversationId];

  @override
  Future<ImConversation?> conversationByPeer(String peerId) async {
    for (final c in _d.conversations.values) {
      if (c.peer.userId == peerId) return c;
    }
    return null;
  }

  @override
  Future<List<ImConversation>> listConversations() async {
    final list = _d.conversations.values.toList()
      ..sort((a, b) {
        final pa = a.pinnedAt, pb = b.pinnedAt;
        if ((pa == null) != (pb == null)) return pa == null ? 1 : -1;
        final p = pa == null ? 0 : pb!.compareTo(pa);
        if (p != 0) return p;
        final t = b.lastMsgAt.compareTo(a.lastMsgAt);
        return t != 0 ? t : b.id.compareTo(a.id);
      });
    return list;
  }

  @override
  Future<ImConversation?> setReadSeq(int conversationId, int readSeq) async {
    final d = _d;
    final c = d.conversations[conversationId];
    if (c == null) return null;
    if (readSeq <= c.readSeq) return c;
    return d.conversations[conversationId] = c.copyWith(readSeq: readSeq);
  }

  @override
  Future<void> markAllRead() async {
    final d = _d;
    d.conversations.updateAll(
      (_, c) => c.copyWith(readSeq: math.max(c.readSeq, c.maxSeq)),
    );
  }

  @override
  Future<int> totalUnread() async => _d.conversations.values.fold<int>(
    0,
    (s, c) => c.muted ? s : s + c.unread,
  );

  @override
  Future<void> clearMessages(int conversationId, int clearSeq) async {
    final d = _d;
    final c = d.conversations[conversationId];
    if (c == null || clearSeq <= c.clearSeq) return;
    d.conversations[conversationId] = clearedConversation(c, clearSeq);
    d.removeMessages(
      (m) =>
          m.conversationId == conversationId &&
          m.seq != null &&
          m.seq! <= clearSeq,
    );
    final synced = d.synced[conversationId] ?? 0;
    await setSyncedSeq(conversationId, math.max(synced, clearSeq));
  }

  @override
  Future<void> deleteConversation(int conversationId) async {
    final d = _d;
    final peer = d.conversations.remove(conversationId)?.peer.userId;
    d.synced.remove(conversationId);
    d.removeMessages(
      (m) =>
          m.conversationId == conversationId ||
          (m.seq == null && m.isSelf && m.to == peer),
    );
  }

  @override
  Future<String?> changesCursor() async => _d.changesCursor;

  @override
  Future<void> setChangesCursor(String cursor) async =>
      _d.changesCursor = cursor;

  @override
  Future<String?> recallsCursor() async => _d.recallsCursor;

  @override
  Future<void> setRecallsCursor(String cursor) async =>
      _d.recallsCursor = cursor;

  @override
  Future<ImConversation?> setPeerReadSeq(
    int conversationId,
    int peerReadSeq,
  ) async {
    final d = _d;
    final c = d.conversations[conversationId];
    if (c == null || peerReadSeq <= (c.peerReadSeq ?? -1)) return c;
    return d.conversations[conversationId] = c.copyWith(
      peerReadSeq: peerReadSeq,
    );
  }

  @override
  Future<int> syncedSeq(int conversationId) async =>
      _d.synced[conversationId] ?? 0;

  @override
  Future<int> setSyncedSeq(int conversationId, int seq) async {
    final d = _d;
    if (!d.conversations.containsKey(conversationId)) return 0;
    final seqs = [
      for (final m in d.messages.values)
        if (m.conversationId == conversationId && m.seq != null && m.seq! > seq)
          m.seq!,
    ]..sort();
    return d.synced[conversationId] = advanceSynced(seq, seqs);
  }

  // ---------------- 消息 ----------------

  @override
  Future<ImUpsertResult> upsertMessage(ImMessage message) async {
    final d = _d;
    var localId = message.id == null ? null : d.byId[message.id];
    localId ??= d.byCid[_cidKey(message.from, message.clientMsgId)];
    final inserted = localId == null;
    final merged = inserted
        ? message
        : mergeMessage(d.messages[localId]!, message);
    if (isConfirmed(merged) &&
        merged.seq! <=
            (d.conversations[merged.conversationId]?.clearSeq ?? 0)) {
      d.removeMessages(
        (m) => m.from == merged.from && m.clientMsgId == merged.clientMsgId,
      );
      return (message: merged, inserted: false);
    }
    localId ??= d.nextLocalId++;

    d.messages[localId] = merged;
    d.byCid[_cidKey(merged.from, merged.clientMsgId)] = localId;
    if (merged.id != null) d.byId[merged.id!] = localId;

    if (isConfirmed(merged)) {
      final convId = merged.conversationId!;
      final bumped = bumpConversation(d.conversations[convId], merged);
      if (bumped != null) d.conversations[convId] = bumped;
      final synced = d.synced[convId] ?? 0;
      if (synced > 0 && merged.seq == synced + 1) {
        await setSyncedSeq(convId, synced);
      }
    }
    return (message: merged, inserted: inserted);
  }

  @override
  Future<List<ImUpsertResult>> upsertMessages(List<ImMessage> messages) async =>
      [for (final m in messages) await upsertMessage(m)];

  @override
  Future<ImMessage?> getMessageById(int id) async {
    final d = _d;
    final l = d.byId[id];
    return l == null ? null : d.messages[l];
  }

  @override
  Future<ImMessage?> getMessageByClientMsgId(
    String from,
    String clientMsgId,
  ) async {
    final d = _d;
    final l = d.byCid[_cidKey(from, clientMsgId)];
    return l == null ? null : d.messages[l];
  }

  Iterable<ImMessage> _confirmedIn(int conversationId) => _d.messages.values
      .where((m) => m.conversationId == conversationId && m.seq != null);

  @override
  Future<List<ImMessage>> messages(
    int conversationId, {
    int? beforeSeq,
    int limit = 30,
  }) async {
    final list =
        _confirmedIn(
            conversationId,
          ).where((m) => beforeSeq == null || m.seq! < beforeSeq).toList()
          ..sort((a, b) => a.seq!.compareTo(b.seq!));
    return list.length <= limit ? list : list.sublist(list.length - limit);
  }

  @override
  Future<int> maxLocalSeq(int conversationId) async =>
      _confirmedIn(conversationId).fold<int>(0, (s, m) => math.max(s, m.seq!));

  @override
  Future<bool> isContiguous(int conversationId, int fromSeq, int toSeq) async {
    if (fromSeq > toSeq) return true;
    final have = {
      for (final m in _confirmedIn(conversationId))
        if (m.seq! >= fromSeq && m.seq! <= toSeq) m.seq!,
    };
    return have.length == toSeq - fromSeq + 1;
  }

  @override
  Future<List<ImMessage>> unconfirmedMessages(String peerId) async {
    final d = _d;
    final keys = d.messages.keys.toList()..sort();
    return [
      for (final k in keys)
        if (d.messages[k]!.seq == null &&
            d.messages[k]!.isSelf &&
            d.messages[k]!.to == peerId)
          d.messages[k]!,
    ];
  }
}
