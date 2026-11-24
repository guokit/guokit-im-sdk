/// 对账、推送处理、补拉（spec §3.4）。
///
/// 对账与推送处理都进同一个串行队列，避免并发补拉交错；单个任务失败只交给 [ImSync.onError]，不影响后续任务。
/// 一个实例对应一次登录，登出时 [ImSync.close]，队列里剩下的任务直接跳过。
library;

import 'dart:math' as math;

import 'api.dart';
import 'errors.dart';
import 'models.dart';
import 'store.dart';
import 'time.dart';

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

  /// 本次登录期间删除过的会话 → 删除时的 clearSeq。会话行已经没了，
  /// 靠它挡住删除前发出、删除后才返回的拉消息结果，否则旧消息会把会话又建出来。
  final Map<int, int> _deletedSeq = {};

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

  /// 排一次会话设置应用（本设备的置顶 / 免打扰 / 清空 / 删除接口返回后调）。进队列，不与补拉交错。
  Future<void> applySettings(Map settings) => _enqueue(() async {
    await _applySettings(settings);
    await onChanged();
  });

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
      await _upsertPage(page.items);
      if (!advanced) break;
      cursor = page.nextCursor;
    } while (cursor != null);

    // 2. 补齐离线期间别的设备改的会话设置。会话列表只含可见会话，且不一定翻到底，
    // 「已删除」只能从这里知道。旧版服务端没有这个接口，失败不影响下面的补拉，下次对账再补。
    await _tolerate(_pullChanges);

    // 3. 只补拉拉过消息（syncedSeq > 0）且落后的会话；从没拉过的等打开时由 messages() 拉最新一页。
    for (final c in await store.listConversations()) {
      final synced = await store.syncedSeq(c.id);
      if (synced > 0 && synced < c.maxSeq) {
        await pullAfter(c.id, synced, notify: true);
      }
    }
    await onChanged();
  }

  /// 写入会话列表的一页。`clearSeq` 变大的会话先清掉旧消息再写会话行。
  Future<void> _upsertPage(List<ImConversation> items) async {
    for (final c in items) {
      if (c.clearSeq > 0) await store.clearMessages(c.id, c.clearSeq);
    }
    await store.upsertConversations(items);
  }

  Future<void> _pullChanges() async {
    var cursor = await store.changesCursor();
    while (true) {
      final r = await api.conversationChanges(cursor: cursor, limit: 200);
      if (_closed) return; // 已登出，库可能已换成别的用户的，游标不能写进去
      for (final s in r.items) {
        await _applySettings(s);
      }
      cursor = r.nextCursor;
      if (cursor.isEmpty) return;
      await store.setChangesCursor(cursor);
      if (!r.hasMore) return;
    }
  }

  /// 用一份会话设置（写接口返回、`conversation_changed` 推送、增量补齐）覆盖本地，可重复应用。
  Future<void> _applySettings(Map s) async {
    final id = (s['conversation_id'] as num).toInt();
    final clearSeq = (s['clear_seq'] as num).toInt();
    final local = await store.getConversation(id);
    // 删除时 clearSeq 就是当时的最大 seq。本地已有更新的消息，说明会话在删除后又因新消息出现、
    // 这份设置是旧的（如接口返回晚于新消息推送），只清空、不删会话。
    if (s['visible'] == false && (local == null || local.maxSeq <= clearSeq)) {
      _deletedSeq[id] = math.max(_deletedSeq[id] ?? 0, clearSeq);
      await store.deleteConversation(id);
      return;
    }
    // 本地还没有的会话由会话列表带出来（列表项自带这些字段）。
    if (local == null) return;
    await store.clearMessages(id, clearSeq);
    final pinnedAt = s['pinned_at'] as String?;
    final cur = (await store.getConversation(id))!;
    await store.upsertConversations([
      cur.copyWith(
        pinnedAt: pinnedAt == null ? null : parseCst(pinnedAt),
        muted: s['muted'] as bool,
      ),
    ]);
  }

  Future<void> _push(Map<String, dynamic> ev) async {
    switch (ev['event']) {
      case 'message':
        final convId = (ev['conversation_id'] as num).toInt();
        final seq = (ev['seq'] as num).toInt();
        if (await store.getConversation(convId) == null) {
          // 本地没有：新会话，或删除后又来新消息的会话。列表首页是「全部置顶 + 最新一页非置顶」，
          // 刚有消息的会话必在其中，拉一次拿 peer。请求失败时退回占位会话：
          // 昵称头像为空、免打扰未知，下次对账补全。
          await _tolerate(() async {
            final page = await api.conversations();
            await _upsertPage(page.items);
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
      case 'conversation_changed':
        // 每次都带完整设置，不必按 action 推算：清空看 clear_seq，删除看 visible。
        await _applySettings(ev['conversation'] as Map);
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
  /// 清空 / 删除范围内的消息丢弃（清空的由存储层按 `clearSeq` 挡，删除的会话行已没了，在这里挡）。
  Future<void> ingest(
    int conversationId,
    List<Map> raw, {
    required bool notify,
  }) async {
    final conv = await store.getConversation(conversationId);
    final floor = _deletedSeq[conversationId] ?? 0;
    final msgs = [
      for (final j in raw)
        if ((j['seq'] as num) > floor)
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
