/// 对账、推送处理、补拉（spec §3.4）。
///
/// 对账与推送处理都进同一个串行队列，避免并发补拉交错；单个任务失败只交给 [ImSync.onError]，不影响后续任务。
/// 一个实例对应一次登录，登出时 [ImSync.close]，队列里剩下的任务直接跳过。
library;

import 'api.dart';
import 'errors.dart';
import 'models.dart';
import 'store.dart';

class ImSync {
  ImSync({
    required this.api,
    required this.store,
    required this.me,
    required this.onNewMessage,
    required this.onMessageUpdated,
    required this.onChanged,
    required this.onError,
  });

  final ImApi api;
  final ImStore store;

  /// 当前登录用户。
  final String me;

  /// 新入库的消息（推送、对账补拉、跳号补拉入库的；翻历史不算）。
  final void Function(ImMessage) onNewMessage;

  /// 本设备未确认（sending / failed）的消息被服务端版本合并成 sent。
  final void Function(ImMessage) onMessageUpdated;

  /// 会话或未读有变化，门面据此推快照与总未读。
  final Future<void> Function() onChanged;

  /// 队列任务失败（门面只关心 [ImKickedOutException]，其余忽略）。
  final void Function(Object error) onError;

  /// 补拉一页的条数（服务端上限 100）。
  static const int pullLimit = 100;

  bool _closed = false;
  Future<void> _tail = Future<void>.value();
  Future<void>? _pendingReconcile;

  /// 队列排空时完成（测试用）。
  Future<void> get idle => _tail;

  void close() => _closed = true;

  Future<void> _enqueue(Future<void> Function() job) {
    final f = _tail.then((_) async {
      if (_closed) return;
      try {
        await job();
      } catch (e) {
        if (!_closed) onError(e);
      }
    });
    _tail = f;
    return f;
  }

  /// 排一次对账。队列里已有一次还没开始的对账时复用它，不重复排。
  Future<void> reconcile() => _pendingReconcile ??= _enqueue(() {
    _pendingReconcile = null;
    return _reconcile();
  });

  /// 排一条推送（长连接 publication 解码后的 Map）。
  Future<void> handlePush(Map<String, dynamic> ev) => _enqueue(() => _push(ev));

  Future<void> _reconcile() async {
    // 1. 翻会话列表；一整页的 maxSeq 都不超过本地记录时停止翻页。
    String? cursor;
    do {
      final page = await api.conversations(cursor: cursor, limit: 50);
      var advanced = false;
      for (final c in page.items) {
        final local = await store.getConversation(c.id);
        if (local == null || c.maxSeq > local.maxSeq) advanced = true;
      }
      await store.upsertConversations(page.items);
      if (!advanced) break;
      cursor = page.nextCursor;
    } while (cursor != null);

    // 2. 只补拉拉过消息（syncedSeq > 0）且落后的会话；从没拉过的等打开时由 messages() 拉最新一页。
    for (final c in await store.listConversations()) {
      final synced = await store.syncedSeq(c.id);
      if (synced > 0 && synced < c.maxSeq) {
        await pullAfter(c.id, synced, notify: true);
      }
    }
    await onChanged();
  }

  Future<void> _push(Map<String, dynamic> ev) async {
    switch (ev['event']) {
      case 'message':
        final convId = (ev['conversation_id'] as num).toInt();
        final seq = (ev['seq'] as num).toInt();
        if (await store.getConversation(convId) == null) {
          // 新会话一定在会话列表首页最前，拉一次拿 peer。
          await _tolerate(() async {
            final page = await api.conversations();
            await store.upsertConversations(page.items);
          });
        }
        final synced = await store.syncedSeq(convId);
        if (synced > 0 && seq > synced + 1) {
          // 跳号：先补中间段。失败也照样入库这条，断档留给下次对账。
          await _tolerate(() => pullAfter(convId, synced, notify: true));
        }
        await ingest(convId, [ev['message'] as Map], notify: true);
      case 'read':
        await store.setReadSeq(
          (ev['conversation_id'] as num).toInt(),
          (ev['read_seq'] as num).toInt(),
        );
      case 'read_all':
        await store.markAllRead();
      default:
        return;
    }
    await onChanged();
  }

  /// 吞掉除 [ImKickedOutException] 以外的异常。
  Future<void> _tolerate(Future<void> Function() f) async {
    try {
      await f();
    } on ImKickedOutException {
      rethrow;
    } catch (_) {}
  }

  /// 按 `after_seq` 补拉到追平（has_more 循环）。不进队列，门面 `messages()` 也直接调。
  Future<void> pullAfter(
    int conversationId,
    int afterSeq, {
    required bool notify,
  }) async {
    var cursor = afterSeq;
    while (true) {
      final r = await api.messages(
        conversationId,
        afterSeq: cursor,
        limit: pullLimit,
      );
      if (r.items.isEmpty) return;
      await ingest(conversationId, r.items, notify: notify);
      if (!r.hasMore) return;
      cursor = (r.items.last['seq'] as num).toInt();
    }
  }

  /// 把服务端消息对象转模型并入库。[notify] 为 true 时新插入的发 [onNewMessage]；
  /// 不论 [notify]，本设备未确认的消息被合并成 sent 时发 [onMessageUpdated]。
  Future<void> ingest(
    int conversationId,
    List<Map> raw, {
    required bool notify,
  }) async {
    final conv = await store.getConversation(conversationId);
    final msgs = [
      for (final j in raw)
        ImMessage.fromServer(j, me: me, peerId: conv?.peer.userId),
    ];
    final prev = <int, ImMessageStatus>{};
    for (var i = 0; i < msgs.length; i++) {
      if (!msgs[i].isSelf) continue;
      final p = await store.getMessageByClientMsgId(me, msgs[i].clientMsgId);
      if (p != null) prev[i] = p.status;
    }
    final results = await store.upsertMessages(msgs);
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      if (r.inserted) {
        if (notify) onNewMessage(r.message);
      } else if (prev[i] != null && prev[i] != ImMessageStatus.sent) {
        onMessageUpdated(r.message);
      }
    }
  }
}
