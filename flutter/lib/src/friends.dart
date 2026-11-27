import 'dart:async';

import 'api.dart';
import 'errors.dart';
import 'models.dart';
import 'session_store.dart';

/// 好友缓存，只放内存（不进 [ImStore]：它是可注入的公开抽象，加方法会破坏接入方实现）。
/// 离线冷启动为空，连上后补齐。懒加载：本次登录调用过 `friends()` 之后，才在连上时全量重拉；
/// 对账单独排队、失败不影响会话（旧服务端没有 `/friends`）。
class FriendBook {
  FriendBook({
    required this.api,
    required this.store,
    required this.onFriends,
    required this.onConversations,
    required this.onKickedOut,
  });

  final ImApi api;
  final SessionStore store;

  /// 好友快照变了（按 userId 升序）。
  final void Function(List<ImFriend>) onFriends;

  /// 会话的 peer.remark 被回写了。
  final Future<void> Function() onConversations;
  final void Function() onKickedOut;

  /// 对账每页条数：3000 人上限，最多 6 个请求。
  static const int pageSize = 500;

  Map<String, ImFriend> _map = {};

  /// 本次登录调用过 `friends()`。
  bool used = false;
  bool _closed = false;
  Future<void> _tail = Future<void>.value();
  Future<void>? _pending;

  /// 队列排空时完成（测试用）。
  Future<void> get idle => _tail;

  void close() => _closed = true;

  List<ImFriend> snapshot() =>
      _map.values.toList()..sort((a, b) => a.userId.compareTo(b.userId));

  ImFriend? get(String userId) => _map[userId];

  /// 全量重拉并整份覆盖；队列里已有一次还没开始的就复用。
  Future<void> reconcile() => _pending ??= _enqueue(() async {
    _pending = null;
    final next = <String, ImFriend>{};
    String? cursor;
    do {
      final page = await api.friends(cursor: cursor, limit: pageSize);
      for (final f in page.items) {
        next[f.userId] = f;
      }
      cursor = page.nextCursor;
    } while (cursor != null);
    if (_closed) return;
    final remarks = {for (final id in _map.keys) id: ''};
    for (final f in next.values) {
      remarks[f.userId] = f.remark;
    }
    _map = next;
    onFriends(snapshot());
    if (await _setRemarks(remarks)) await onConversations();
  });

  /// friend_changed 推送，或本设备写接口的结果。进同一队列，不与对账交错。
  Future<void> apply(String action, ImFriend f) => _enqueue(() async {
    if (_closed) return;
    var remark = f.remark;
    if (action == 'removed') {
      _map.remove(f.userId);
      remark = '';
    } else {
      _map[f.userId] = f;
    }
    onFriends(snapshot());
    if (await _setRemarks({f.userId: remark})) await onConversations();
  });

  /// 按对方回写会话备注（userId → 备注）：会话对账翻完首轮后不再重拉后面的页，不回写就会过期。
  /// 只用 ImStore 已有的方法（列出会话 + 写回），不给接入方的存储实现加接口。
  Future<bool> _setRemarks(Map<String, String> remarks) async {
    if (remarks.isEmpty) return false;
    final changed = [
      for (final c in await store.listConversations())
        if (remarks.containsKey(c.peer.userId) &&
            c.peer.remark != remarks[c.peer.userId])
          c.copyWith(peer: c.peer.copyWith(remark: remarks[c.peer.userId])),
    ];
    if (changed.isEmpty) return false;
    await store.upsertConversations(changed);
    return true;
  }

  Future<void> _enqueue(Future<void> Function() job) {
    final f = _tail.then((_) async {
      if (_closed) return;
      try {
        await job();
      } catch (e) {
        if (!_closed && e is ImKickedOutException) onKickedOut();
      }
    });
    _tail = f;
    return f;
  }
}
