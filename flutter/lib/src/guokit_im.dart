/// 门面 [GuokitIm]：组装 HTTP、令牌、存储、长连接与同步，对外只暴露 Dart 自带的 `Stream`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import 'api.dart';
import 'errors.dart';
import 'models.dart';
import 'realtime.dart';
import 'store.dart';
import 'store_factory.dart';
import 'sender.dart';
import 'session_store.dart';
import 'sync.dart';
import 'token.dart';

/// SDK 配置。
class ImConfig {
  const ImConfig({
    required this.baseUrl,
    required this.tokenProvider,
    this.store,
    this.httpClient,
    this.realtimeFactory,
  });

  /// IM 服务地址，如 `https://im.example.com`。长连接地址由它推导（https → wss）。
  final String baseUrl;

  /// 向自家后端取 IM 令牌。用户已封禁 / 已登出时抛 [ImKickedOutException]（spec §3.6）。
  final Future<ImToken> Function() tokenProvider;

  /// 本地存储；默认 iOS / Android 用 SQLite、Web 用内存。桌面端需自行注入。
  final ImStore? store;

  /// HTTP 客户端（测试注入），默认新建。
  final http.Client? httpClient;

  /// 长连接实现（测试注入），默认 centrifuge。
  final ImRealtimeFactory? realtimeFactory;
}

/// 一次登录的全部状态，登出整套作废：换号后旧账号的在途请求、回调都落不到新账号上。
class _Session {
  _Session({
    required this.me,
    required this.store,
    required this.tokens,
    required this.api,
  });

  final String me;
  final SessionStore store;
  final TokenManager tokens;
  final ImApi api;
  late final ImSync sync;
  late final ImSender sender;
  ImRealtime? rt;
  StreamSubscription<ImRealtimeEvent>? rtSub;
  String? rtToken;
  bool kicked = false;

  /// 连续 3500 换令牌重连的次数，连上后清零；到上限就停（防止 provider 一直给坏令牌时死循环）。
  int authRetries = 0;

  /// 正在输入的会话 → 到期计时器。
  final Map<int, Timer> typingTimers = {};

  /// 会话 → 上次告诉对方「正在输入」的时间，按 3 秒节流。
  final Map<int, DateTime> typingSent = {};

  /// 本次登录已用标已读上报到的 seq。不能只看 readSeq：一键清未读会把它推满，
  /// 之后打开聊天若不再上报，对方就永远看不到「已读」。
  final Map<int, int> reportedRead = {};
}

class GuokitIm {
  GuokitIm(this.config)
    : _store = config.store ?? createDefaultStore(),
      _client = config.httpClient ?? http.Client();

  final ImConfig config;
  final ImStore _store;

  /// 各次登录的接口层共用。
  final http.Client _client;

  final _newMessage = StreamController<ImMessage>.broadcast();
  final _messageUpdated = StreamController<ImMessage>.broadcast();
  final _conversations = StreamController<List<ImConversation>>.broadcast();
  final _totalUnreadCtrl = StreamController<int>.broadcast();
  final _connection = StreamController<ImConnectionState>.broadcast();
  final _kickedOut = StreamController<void>.broadcast();
  final _typing = StreamController<ImTyping>.broadcast();
  final _sendProgress = StreamController<ImSendProgress>.broadcast();

  _Session? _s;
  int _totalUnread = 0;
  ImConnectionState _state = ImConnectionState.disconnected;

  /// 同一用户的登录还没完成时，再调 login 共用它。
  Future<void>? _loggingIn;
  String? _loggingUser;

  /// 每次登录、登出自增，用来认出「我已被更新的一次取代」。
  int _gen = 0;

  /// 开库、关库的串行队列，见 [_serial]。
  Future<void> _storeOps = Future<void>.value();

  /// 正在登出（或登出收尾失败）的用户。
  String? _closing;

  static const int _maxAuthRetries = 2;

  // ---------------- 状态与事件 ----------------

  /// 当前登录用户，未登录为 null。
  String? get currentUserId => _s?.me;

  /// 当前总未读（各非免打扰会话 `maxSeq − readSeq` 之和）。
  int get totalUnread => _totalUnread;

  ImConnectionState get connectionState => _state;

  /// 新入库的消息：别人发来的，以及本人在其他设备发出的。本设备发出的、已撤回的不走这里。
  Stream<ImMessage> get onNewMessage => _newMessage.stream;

  /// 本地消息变化：发送中 → 成功 / 失败 / 被拒收；图片、语音、文件、视频换新链接；
  /// 变成已撤回（[ImMessage.isRecalled]，不分本人与对方，App 在这里清掉已下载的附件）。
  Stream<ImMessage> get onMessageUpdated => _messageUpdated.stream;

  /// 会话列表快照：置顶会话在前（按置顶时间倒序），其余按最后消息时间倒序。
  Stream<List<ImConversation>> get onConversationsChanged =>
      _conversations.stream;

  /// 总未读；登录时先推一次初始值，之后变化才推。
  Stream<int> get onTotalUnreadChanged => _totalUnreadCtrl.stream;

  Stream<ImConnectionState> get onConnectionChanged => _connection.stream;

  /// 被封禁或踢下线。SDK 已停止重连，App 应走登出。
  Stream<void> get onKickedOut => _kickedOut.stream;

  /// 对方「正在输入」的变化；约 6 秒没有新的、或收到他的消息时自动收起。
  Stream<ImTyping> get onTyping => _typing.stream;

  /// 图片、语音、文件、视频的上传进度（不含视频封面），只报正在传的；结果看 [onMessageUpdated]。
  /// 换令牌重传时从头计。Flutter Web 上会直接跳到 100%：浏览器里先读完整个请求体才发。
  Stream<ImSendProgress> get onSendProgress => _sendProgress.stream;

  /// 同步队列排空时完成。
  @visibleForTesting
  Future<void> get idle => _s?.sync.idle ?? Future<void>.value();

  // ---------------- 登录 / 登出 ----------------

  /// 打开该用户本地库 → 推一次本地快照与总未读初始值 → 取令牌 → 连接；连上后自动对账。
  ///
  /// 不等对账完成就返回。取令牌失败不抛异常：provider 抛 [ImKickedOutException] 走 [onKickedOut]，
  /// 抛其他异常报 `disconnected`；本地数据照常可读。已登录同一用户且已断开时再调一次即重连。
  Future<void> login(String userId) {
    final pending = _loggingIn;
    if (pending != null && _loggingUser == userId) return pending;
    late final Future<void> f;
    f = _login(userId).whenComplete(() {
      if (identical(_loggingIn, f)) _loggingIn = null;
    });
    _loggingUser = userId;
    return _loggingIn = f;
  }

  Future<void> _login(String userId) async {
    final cur = _s;
    if (cur != null && cur.me == userId && !cur.kicked) {
      if (_state == ImConnectionState.disconnected) {
        cur.authRetries = 0; // App 主动重连，3500 重试次数重新算
        await _connect(cur);
      }
      return;
    }
    final gen = ++_gen;
    if (cur != null) await _close(cur, clearCache: false);
    // 打开失败直接抛，状态保持未登录。开库前后各核一次：被更新的登录 / 登出取代的不再继续。
    final s = await _serial(() async {
      if (gen != _gen) return null;
      await _store.open(userId);
      if (gen != _gen) {
        await _store.close();
        return null;
      }
      return _s = _newSession(userId);
    });
    if (s == null) return;
    await _emitSnapshot(s, forceTotal: true);
    await _connect(s);
  }

  _Session _newSession(String me) {
    final tokens = TokenManager(config.tokenProvider);
    final s = _Session(
      me: me,
      store: SessionStore(_store),
      tokens: tokens,
      api: ImApi(baseUrl: config.baseUrl, tokens: tokens, client: _client),
    );
    // 下面的回调都先核会话：登出后不再发事件。
    s.sync = ImSync(
      api: s.api,
      store: s.store,
      me: me,
      onNewMessage: (m) {
        if (!_live(s)) return;
        if (!m.isSelf) _stopTyping(s, m.conversationId!, m.from);
        _newMessage.add(m);
      },
      onMessageUpdated: (m) => _updated(s, m),
      onChanged: () => _emitSnapshot(s),
      onError: (e) {
        if (e is ImKickedOutException) _kick(s);
      },
      onTyping: (id, from, ttl) => _showTyping(s, id, from, ttl),
    );
    s.sender = ImSender(
      api: s.api,
      store: s.store,
      sync: s.sync,
      me: me,
      onUpdated: (m) => _updated(s, m),
      onSnapshot: () => _emitSnapshot(s),
      onKickedOut: () => _kick(s),
      onProgress: (p) {
        if (_live(s)) _sendProgress.add(p);
      },
    );
    return s;
  }

  /// 断开、清令牌、关闭本地库。[clearCache] 为 true 时删除该用户本地库。
  /// 还没返回的调用抛 [StateError]，还在发的消息以 failed / `UNKNOWN` 完成、不发事件。
  ///
  /// 还没完成的 [login] 一并取消，那次调用正常返回但不会登录上。
  Future<void> logout({bool clearCache = false}) {
    _gen++;
    _loggingIn = null;
    final s = _s;
    if (s != null) return _close(s, clearCache: clearCache);
    // 上一次登出还在收尾（或收尾失败）：等它，要清缓存的接着清。
    final left = _closing;
    if (!clearCache || left == null) return _serial(() async {});
    return _serial(() async {
      await _store.deleteAll(left);
      if (_closing == left) _closing = null;
    });
  }

  /// 先整套作废（同步），再排队断连接、关库。
  Future<void> _close(_Session s, {required bool clearCache}) {
    _s = null;
    _closing = s.me;
    s.sync.close();
    s.api.invalidate();
    s.store.invalidate();
    s.tokens.clear();
    for (final t in s.typingTimers.values) {
      t.cancel();
    }
    return _serial(() async {
      try {
        await _closeRealtime(s);
        if (clearCache) {
          await _store.deleteAll(s.me);
        } else {
          await _store.close();
        }
        if (_closing == s.me) _closing = null;
      } finally {
        if (_totalUnread != 0) {
          _totalUnread = 0;
          _totalUnreadCtrl.add(0);
        }
        _setState(ImConnectionState.disconnected);
      }
    });
  }

  /// 开库、关库、删库一个接一个：并发会把别的账号刚打开的库关掉或换掉。
  Future<T> _serial<T>(Future<T> Function() f) {
    final r = _storeOps.then((_) => f());
    _storeOps = r.then((_) {}, onError: (Object _) {});
    return r;
  }

  static Future<void> _closeRealtime(_Session s) async {
    final rt = s.rt;
    s.rt = null;
    await s.rtSub?.cancel();
    s.rtSub = null;
    if (rt == null) return;
    try {
      await rt.close();
    } catch (_) {}
  }

  /// 登出并关闭全部事件流与 HTTP 客户端，之后不能再用。
  Future<void> dispose() async {
    await logout();
    if (config.httpClient == null) _client.close();
    for (final c in [
      _newMessage,
      _messageUpdated,
      _conversations,
      _totalUnreadCtrl,
      _connection,
      _kickedOut,
      _typing,
      _sendProgress,
    ]) {
      await c.close();
    }
  }

  // ---------------- 会话与消息 ----------------

  /// 先返回本地快照，同时在后台排一次对账（结果经 [onConversationsChanged] 推出）。
  Future<List<ImConversation>> conversations() async {
    final s = _session();
    final list = await s.store.listConversations();
    unawaited(s.sync.reconcile());
    return list;
  }

  /// 只查本地。null 可能是还没会话，也可能是还没同步到；聊天页照样可以直接发消息。
  Future<ImConversation?> conversationWith(String peerId) =>
      _session().store.conversationByPeer(peerId);

  /// 发给 [peerId] 的未确认消息（发送中 / 失败 / 被拒收），按 `createdAt` 升序，只查本地。
  ///
  /// 会话建立前第一条消息就发失败时，[conversationWith] 为 null、[messages] 也取不到它；
  /// 聊天页这时调本方法显示这些消息，并可对 failed 的调 [resend]（rejected 不能重发）。已有会话时 [messages] 的最新一页已经附带它们。
  Future<List<ImMessage>> pendingTo(String peerId) async {
    return (await _session().store.unconfirmedMessages(peerId))
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  /// 按 seq 升序返回一页消息，本地优先，本地不连续或不足时从服务端补齐。
  ///
  /// - [before] 为空（或是未确认消息）：最新一页，末尾按 `createdAt` 追加发给该会话对方的未确认消息；
  ///   从没拉过的会话拉服务端最新一页并记下 `syncedSeq`；拉过但落后的先补拉追平。
  /// - [before] 非空：`seq < before.seq` 的 [limit] 条，不含未确认消息。
  Future<List<ImMessage>> messages(
    int conversationId, {
    ImMessage? before,
    int limit = 30,
  }) => _call((s) async {
    final sync = s.sync;
    final store = s.store;
    final beforeSeq = before?.seq;
    // 清空记录后，能看到的第一条是 clearSeq + 1。
    final conv = await store.getConversation(conversationId);
    final firstSeq = (conv?.clearSeq ?? 0) + 1;

    if (beforeSeq != null) {
      if (beforeSeq <= firstSeq) return <ImMessage>[];
      var local = await store.messages(
        conversationId,
        beforeSeq: beforeSeq,
        limit: limit,
      );
      if (!_complete(local, limit, firstSeq, beforeSeq: beforeSeq)) {
        final r = await s.api.messages(
          conversationId,
          beforeSeq: beforeSeq,
          limit: limit,
        );
        await sync.ingest(conversationId, r.items, notify: false);
        local = await store.messages(
          conversationId,
          beforeSeq: beforeSeq,
          limit: limit,
        );
      }
      return local;
    }

    var fetched = false;
    Future<void> fetchLatest() async {
      fetched = true;
      final r = await s.api.messages(conversationId, limit: limit);
      await sync.ingest(conversationId, r.items, notify: false);
      if (r.items.isNotEmpty && await store.syncedSeq(conversationId) == 0) {
        await store.setSyncedSeq(
          conversationId,
          (r.items.last['seq'] as num).toInt(),
        );
      }
    }

    final synced = await store.syncedSeq(conversationId);
    if (synced == 0) {
      await fetchLatest();
    } else if (conv != null && synced < conv.maxSeq) {
      await sync.pullAfter(conversationId, synced, notify: false);
    }
    var local = await store.messages(conversationId, limit: limit);
    if (!fetched && !_complete(local, limit, firstSeq)) {
      await fetchLatest();
      local = await store.messages(conversationId, limit: limit);
    }

    final peer = (await store.getConversation(conversationId))?.peer.userId;
    final pending = peer == null
        ? <ImMessage>[]
        : (await store.unconfirmedMessages(peer)
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt)));
    if (fetched || pending.isNotEmpty) await _emitSnapshot(s);
    return [...local, ...pending];
  });

  /// 本地这一页是否可直接用：seq 连续，条数够或已到能看到的第一条 [firstSeq]，翻历史时还要紧接 [beforeSeq]。
  static bool _complete(
    List<ImMessage> l,
    int limit,
    int firstSeq, {
    int? beforeSeq,
  }) {
    if (l.isEmpty) return false;
    for (var i = 1; i < l.length; i++) {
      if (l[i].seq != l[i - 1].seq! + 1) return false;
    }
    if (beforeSeq != null && l.last.seq != beforeSeq - 1) return false;
    return l.length >= limit || l.first.seq! <= firstSeq;
  }

  /// 标已读到该会话当前最大 seq，更新服务端并即时更新本地未读。
  /// 打开会话、会话打开着时收到新消息都要调：对方的「已读」只由它推进。
  Future<void> markRead(int conversationId) => _call((s) async {
    final conv = await s.store.getConversation(conversationId);
    if (conv == null ||
        (conv.readSeq >= conv.maxSeq &&
            (s.reportedRead[conversationId] ?? 0) >= conv.maxSeq)) {
      return;
    }
    final r = await s.api.markRead(conversationId, conv.maxSeq);
    s.reportedRead[conversationId] = conv.maxSeq;
    await s.store.setReadSeq(conversationId, r.readSeq);
    await _emitSnapshot(s);
  });

  /// 站点开关：能不能撤回、是否显示对方已读、能发多大的文件与视频。登录后取一次即可。
  Future<ImFeatures> features() => _call((s) => s.api.features());

  /// 撤回自己发的一条消息，双方都变成「已撤回」，经 [onMessageUpdated] 发出。需要 IM 服务端 v1.17.0 及以上。
  ///
  /// 未确认（发送中 / 失败）或别人发的抛 [ArgumentError]；没开启、超过时限抛 [ImApiException]
  /// （`IM_RECALL_NOT_ALLOWED`，直接显示 `message`）。与 `send*` 不同，失败会抛。
  Future<void> recall(ImMessage message) {
    final id = message.id;
    if (id == null || !message.isSelf) {
      throw ArgumentError('只能撤回自己已发送的消息');
    }
    return _call((s) async => s.sync.applyRecall(await s.api.recall(id)));
  }

  /// 告诉对方自己正在输入，输入框内容变化时调即可，SDK 按会话 3 秒节流。失败静默（旧服务端、断网、超频）。
  Future<void> sendTyping(int conversationId) async {
    final s = _session();
    final now = DateTime.now();
    final last = s.typingSent[conversationId];
    if (last != null && now.difference(last) < const Duration(seconds: 3)) {
      return;
    }
    s.typingSent[conversationId] = now;
    try {
      await s.api.typing(conversationId);
    } on ImKickedOutException {
      _kick(s);
    } catch (_) {
      // 提示性的，失败不打扰。
    }
  }

  /// 一键清全部未读。
  Future<void> markAllRead() => _call((s) async {
    await s.api.markAllRead();
    await s.store.markAllRead();
    await _emitSnapshot(s);
  });

  /// 置顶 / 取消置顶。超过 50 个、或会话不在列表里（已删除）时抛 [ImApiException]。多端同步。
  Future<void> setPinned(int conversationId, bool pinned) => _change(
    (api) => api.setConversationSettings(conversationId, pinned: pinned),
  );

  /// 开 / 关免打扰：会话自己的 `unread` 照常计数，但不计入总未读。多端同步。
  Future<void> setMuted(int conversationId, bool muted) => _change(
    (api) => api.setConversationSettings(conversationId, muted: muted),
  );

  /// 清空本人这一侧的记录：会话留在列表原位，预览为 null、未读为 0。对方与服务端的记录不受影响。
  /// 本设备还没发成功的消息（发送中 / 失败）不清。
  Future<void> clearConversation(int conversationId) =>
      _change((api) => api.clearConversation(conversationId));

  /// 删除会话：从列表消失，并清空本人这一侧的记录（含本设备没发成功的消息）。之后有新消息时会话会重新出现，
  /// 只能看到新消息；客服会话在坐席回复、欢迎语、转接提示、接待超时提示、评价邀请时也会这样重新出现。免打扰设置保留。
  Future<void> deleteConversation(int conversationId) =>
      _change((api) => api.deleteConversation(conversationId));

  /// 调会话设置写接口，返回的设置进同步队列应用到本地（顺带推快照）。
  Future<void> _change(
    Future<Map<String, dynamic>> Function(ImApi api) request,
  ) => _call((s) async => s.sync.applySettings(await request(s.api)));

  Future<void> block(String userId) => _call((s) => s.api.block(userId));

  Future<void> unblock(String userId) => _call((s) => s.api.unblock(userId));

  Future<({List<ImBlockItem> items, bool hasMore})> blocks({
    int? offset,
    int? limit,
  }) => _call((s) => s.api.blocks(offset: offset, limit: limit));

  /// 举报用户（接入文档 §5.16）。[reason] 取 [reportReasons] 之一；[messageIds] 是对方发的消息 id
  /// （最多 10 条，同一会话），作证据存快照；[block] 为 true 时同时拉黑。
  /// 对同一个人已有待处理的举报时返回原单（duplicated 为 true）。每人每天最多新建 20 张，超出是 IM_RATE_LIMITED。
  Future<({int reportId, bool duplicated})> report(
    String target,
    String reason, {
    String? detail,
    List<int>? messageIds,
    bool block = false,
  }) => _call(
    (s) => s.api.report(
      target,
      reason,
      detail: detail,
      messageIds: messageIds,
      block: block,
    ),
  );

  // ---------------- 客服 ----------------

  /// 当前客服接待状态，用于客服会话页顶部的「排队中，前面还有 N 位」状态条。
  /// 服务端不推送，建议进入客服会话、收到客服新消息时各刷新一次。站点没装客服时抛 [ImApiException]。
  ///
  /// [serviceId] 是客服主体标识（`conversation.serviceId`），不传或空串是平台客服；
  /// 其他主体需要 IM 服务端 v1.20.0，旧服务端会忽略它、给平台客服的状态。
  Future<ImCsState> csState({String? serviceId}) =>
      _call((s) => s.api.csState(serviceId: serviceId));

  /// 转人工（只有平台客服支持），返回转完的状态（排队中或坐席接待中）；当前没有机器人接待时什么都不做，返回当前状态。
  /// 需要 IM 服务端 v1.12.0 及以上，旧服务端上抛 [ImApiException]。
  Future<ImCsState> handoffCs() => _call((s) => s.api.csHandoff());

  /// 评价一次已结束的接待。[sessionId] 取评价邀请消息（`custom`，`content['data']['kind'] == 'imcs_rating'`）
  /// 里的 `content['data']['session_id']`；[rating] 为 1–5、[comment] 去首尾空白后 ≤200 字，不满足抛 [ArgumentError]。
  /// 重复评价、评别人的或未结束的接待抛 [ImApiException]（`VALIDATION`「无法评价」），可把卡片置为已评价。
  /// 评语长度在这里先拦：服务端超长同样回 `VALIDATION`，不拦的话接入方会把没存上的评价当成已评价。
  Future<void> rateCs(int sessionId, int rating, {String? comment}) {
    if (rating < 1 || rating > 5) {
      throw ArgumentError.value(rating, 'rating', '评分须为 1–5');
    }
    if (comment != null && comment.trim().runes.length > 200) {
      throw ArgumentError.value(comment, 'comment', '评语不能超过 200 字');
    }
    return _call((s) => s.api.csRate(sessionId, rating, comment: comment));
  }

  static final _leavePhone = RegExp(r'^[0-9+\- ]{5,30}$');

  /// 没有坐席在时留联系方式（只有平台客服支持），把这次排队立刻转成留言，返回单号。[ImCsState.canLeave] 为 true 时再给用户表单；
  /// 留言内容不用另填，就是用户这次在会话里说的话。
  ///
  /// [phone] 与 [email] 至少填一项，都去首尾空白：称呼 ≤50 字，电话为 5–30 位数字、`+`、`-`、空格，
  /// 邮箱 ≤120 字节；不满足抛 [ArgumentError]，邮箱格式由服务端校验。
  ///
  /// 成功后这次排队结束（状态变 [ImCsStatus.none]），会收到一条带单号的系统消息，请再取一次 [csState]。
  /// 已经转成留言的再调，只更新那张单的联系方式。
  ///
  /// 抛 [ImApiException]：`VALIDATION`（有坐席在、还没说过话、留言已处理完、格式不对；没装工单或没开留言时
  /// `httpStatus` 为 404），直接显示 `message`；`IM_RATE_LIMITED` 是每小时 5 次，**不要按
  /// [ImApiException.isTemporary] 自动重试**；其余的提示稍后再试。需要 IM 服务端 v1.13.0 及以上。
  Future<String> leaveCs({String? name, String? phone, String? email}) {
    final n = name?.trim() ?? '';
    final p = phone?.trim() ?? '';
    final e = email?.trim() ?? '';
    if (p.isEmpty && e.isEmpty) {
      throw ArgumentError('电话与邮箱至少填一项');
    }
    if (n.runes.length > 50) {
      throw ArgumentError.value(name, 'name', '称呼不能超过 50 字');
    }
    if (p.isNotEmpty && !_leavePhone.hasMatch(p)) {
      throw ArgumentError.value(phone, 'phone', '电话须为 5–30 位数字、+、-、空格');
    }
    if (utf8.encode(e).length > 120) {
      throw ArgumentError.value(email, 'email', '邮箱不能超过 120 字节');
    }
    return _call((s) => s.api.csLeave(name: n, phone: p, email: e));
  }

  // ---------------- 发送 ----------------
  //
  // 都返回 `Future<ImMessage>`：本地「发送中」消息立即经 [onMessageUpdated] 发出，Future 在终态
  // （sent / failed / rejected）完成。**发送失败不抛异常**，看 `status` 与 `errorCode`（含义见 sender.dart）。
  // 只有未登录（StateError）、参数用错（ArgumentError / UnsupportedError）这类编程错误会抛。

  /// 发文本。
  Future<ImMessage> sendText(String to, String text) =>
      _session().sender.sendText(to, text);

  /// 按文件路径发图（iOS / Android）。Web 上抛 [UnsupportedError]，请用 [sendImageBytes]。
  Future<ImMessage> sendImage(String to, String filePath) =>
      _session().sender.sendImage(to, filePath);

  /// 按字节发图（Web 必须用这个）。
  Future<ImMessage> sendImageBytes(
    String to,
    Uint8List bytes, {
    String filename = 'image.jpg',
  }) => _session().sender.sendImageBytes(to, bytes, filename: filename);

  /// 按文件路径发语音（iOS / Android），m4a（AAC）或 mp3，60 秒、2MB 以内。录音由 App 自己做。
  /// Web 上抛 [UnsupportedError]，请用 [sendVoiceBytes]。需要 IM 服务端 v1.17.0 及以上。
  Future<ImMessage> sendVoice(String to, String filePath, Duration duration) =>
      _session().sender.sendVoice(to, filePath, duration);

  /// 按字节发语音。
  Future<ImMessage> sendVoiceBytes(
    String to,
    Uint8List bytes,
    Duration duration, {
    String filename = 'voice.m4a',
  }) =>
      _session().sender.sendVoiceBytes(to, bytes, duration, filename: filename);

  /// 按文件路径发文件（iOS / Android），边读边传，不整个读进内存。[name] 缺省取路径里的文件名，
  /// 扩展名要和内容对得上（可发的类型见接入文档 §5.6）。大小上限先看 [features] 的 `fileMaxMb`，0 = 不能发。
  /// Web 上抛 [UnsupportedError]，请用 [sendFileBytes]。需要 IM 服务端 v1.19.0 及以上。
  Future<ImMessage> sendFile(String to, String filePath, {String? name}) =>
      _session().sender.sendFile(to, filePath, name: name);

  /// 按字节发文件。[name] 要带扩展名。
  Future<ImMessage> sendFileBytes(
    String to,
    Uint8List bytes, {
    required String name,
  }) => _session().sender.sendFileBytes(to, bytes, name: name);

  /// 按文件路径发视频（iOS / Android），边读边传。只收 mp4 与 mov，发送前请转成 H.264 的 MP4，
  /// HEVC（iPhone 默认拍的）很多浏览器放不了。大小上限先看 [features] 的 `videoMaxMb`，0 = 不能发。
  ///
  /// [duration] 1 秒–1 小时，[width] / [height] 1–20000，越界抛 [ArgumentError]；[coverBytes] 是封面图片，由 App 自己截。
  /// 封面只在内存里：还没传上去进程就退出的，重发时不带封面；服务端不收的封面直接不带。
  /// Web 上抛 [UnsupportedError]，请用 [sendVideoBytes]。需要 IM 服务端 v1.19.0 及以上。
  Future<ImMessage> sendVideo(
    String to,
    String filePath, {
    required Duration duration,
    required int width,
    required int height,
    Uint8List? coverBytes,
  }) => _session().sender.sendVideo(
    to,
    filePath,
    duration: duration,
    width: width,
    height: height,
    coverBytes: coverBytes,
  );

  /// 按字节发视频。
  Future<ImMessage> sendVideoBytes(
    String to,
    Uint8List bytes, {
    required Duration duration,
    required int width,
    required int height,
    Uint8List? coverBytes,
    String filename = 'video.mp4',
  }) => _session().sender.sendVideoBytes(
    to,
    bytes,
    duration: duration,
    width: width,
    height: height,
    coverBytes: coverBytes,
    filename: filename,
  );

  /// 发位置。
  Future<ImMessage> sendLocation(
    String to,
    double lat,
    double lng, {
    String? name,
    String? address,
  }) => _session().sender.sendLocation(
    to,
    lat,
    lng,
    name: name,
    address: address,
  );

  /// 发自定义消息。[data] 必须是 JSON 对象，[desc] 用于会话预览与离线推送文字。
  Future<ImMessage> sendCustom(
    String to,
    Map<String, dynamic> data,
    String desc,
  ) => _session().sender.sendCustom(to, data, desc);

  /// 重发 failed 消息，沿用原 clientMsgId。传入非 failed（含 rejected）抛 [ArgumentError]。
  Future<ImMessage> resend(ImMessage failed) =>
      _session().sender.resend(failed);

  /// 图片可用地址：外链图原样返回；上传图链接过期（取得超过 20 小时或为空）时重拉这条消息，
  /// 更新本地并发 [onMessageUpdated] 后返回新地址；重拉失败返回旧地址。非图片返回 null。
  /// 未确认（发送中 / 失败）的上传图返回上传时拿到的临时链接（约 24 小时有效），按路径发的图优先用 `localPath`。
  Future<String?> imageUrl(ImMessage message) =>
      _session().sender.imageUrl(message);

  /// 语音可用地址，规则同 [imageUrl]；非语音返回 null。播放由 App 自己做。
  Future<String?> voiceUrl(ImMessage message) =>
      _session().sender.voiceUrl(message);

  /// 文件下载地址（强制下载、带原文件名），规则同 [imageUrl]；非文件返回 null。下载由 App 自己做。
  Future<String?> fileUrl(ImMessage message) =>
      _session().sender.fileUrl(message);

  /// 视频可用地址，规则同 [imageUrl]；非视频返回 null。播放由 App 自己做。
  Future<String?> videoUrl(ImMessage message) =>
      _session().sender.videoUrl(message);

  /// 视频封面可用地址，规则同 [imageUrl]；非视频、没有封面返回 null。
  Future<String?> videoCoverUrl(ImMessage message) =>
      _session().sender.videoCoverUrl(message);

  // ---------------- 内部 ----------------

  void _showTyping(_Session s, int conversationId, String from, Duration ttl) {
    if (!_live(s)) return;
    s.typingTimers.remove(conversationId)?.cancel();
    s.typingTimers[conversationId] = Timer(
      ttl,
      () => _stopTyping(s, conversationId, from),
    );
    _typing.add(
      ImTyping(conversationId: conversationId, from: from, active: true),
    );
  }

  void _stopTyping(_Session s, int conversationId, String from) {
    final t = s.typingTimers.remove(conversationId);
    if (t == null) return;
    t.cancel();
    if (!_live(s)) return;
    _typing.add(
      ImTyping(conversationId: conversationId, from: from, active: false),
    );
  }

  bool _live(_Session s) => identical(_s, s);

  _Session _session() => _s ?? (throw StateError('GuokitIm 未登录'));

  void _updated(_Session s, ImMessage m) {
    if (_live(s)) _messageUpdated.add(m);
  }

  /// HTTP 调用统一入口：换令牌时 provider 抛 [ImKickedOutException] 先走 [onKickedOut] 再上抛。
  Future<T> _call<T>(Future<T> Function(_Session s) f) async {
    final s = _session();
    try {
      return await f(s);
    } on ImKickedOutException {
      _kick(s);
      rethrow;
    }
  }

  void _setState(ImConnectionState s) {
    if (_state == s) return;
    _state = s;
    _connection.add(s);
  }

  /// 期间登出了就什么都不发。
  Future<void> _emitSnapshot(_Session s, {bool forceTotal = false}) async {
    if (!_live(s)) return;
    final list = await s.store.listConversations();
    if (!_live(s)) return;
    final total = await s.store.totalUnread();
    if (!_live(s)) return;
    _conversations.add(list);
    if (forceTotal || total != _totalUnread) {
      _totalUnread = total;
      _totalUnreadCtrl.add(total);
    }
  }

  Future<void> _connect(_Session s) async {
    if (!_live(s)) return;
    _setState(ImConnectionState.connecting);
    final String token;
    try {
      token = await s.tokens.current();
    } on ImKickedOutException {
      _kick(s);
      return;
    } catch (_) {
      if (_live(s)) _setState(ImConnectionState.disconnected);
      return;
    }
    if (!_live(s) || s.kicked) return;
    var rt = s.rt;
    if (rt == null) {
      final factory = config.realtimeFactory ?? CentrifugeRealtime.new;
      rt = s.rt = factory(imWebSocketUrl(config.baseUrl), token);
      s.rtSub = rt.events.listen((e) => _onRealtime(s, e));
    } else {
      rt.setToken(token);
    }
    s.rtToken = token;
    try {
      await rt.connect();
    } catch (_) {
      if (_live(s)) _setState(ImConnectionState.disconnected);
    }
  }

  void _onRealtime(_Session s, ImRealtimeEvent e) {
    if (!_live(s) || s.kicked) return;
    try {
      switch (e) {
        case ImRealtimeConnecting():
          _setState(ImConnectionState.connecting);
        case ImRealtimeConnected():
          s.authRetries = 0;
          _setState(ImConnectionState.connected);
          unawaited(s.sync.reconcile());
        case ImRealtimeDisconnected(:final code):
          if (code == 3503) {
            _kick(s);
          } else if (code == 3500) {
            unawaited(_reauth(s));
          } else {
            _setState(ImConnectionState.disconnected);
          }
        case ImRealtimePublication(:final data):
          unawaited(s.sync.handlePush(data));
      }
    } catch (_) {
      // 事件处理不能抛出去。
    }
  }

  /// 3500：换令牌（单次）后 setToken + connect。3500 不触发 centrifuge 的 getToken，要手动做。
  Future<void> _reauth(_Session s) async {
    if (s.authRetries >= _maxAuthRetries) {
      // 缓存里还是刚被拒的令牌，丢掉它：否则再调 login 时 _connect 会拿它连、又收 3500，
      // 永远不再调 provider。别的请求已换过新令牌时缓存不等于 rtToken，保留。
      if (s.rtToken != null && s.tokens.cached?.token == s.rtToken) {
        s.tokens.clear();
      }
      _setState(ImConnectionState.disconnected);
      return;
    }
    s.authRetries++;
    _setState(ImConnectionState.connecting);
    try {
      final t = await s.tokens.refresh(stale: s.rtToken);
      final rt = s.rt;
      if (!_live(s) || s.kicked || rt == null) return;
      s.rtToken = t;
      rt.setToken(t);
      await rt.connect();
    } on ImKickedOutException {
      _kick(s);
    } catch (_) {
      if (_live(s)) _setState(ImConnectionState.disconnected);
    }
  }

  /// 被封 / 被踢：停止重连，不再调 provider，发 [onKickedOut]。本地库保持打开，等 App 调 [logout]。
  void _kick(_Session s) {
    if (!_live(s) || s.kicked) return;
    s.kicked = true;
    _setState(ImConnectionState.disconnected);
    _kickedOut.add(null);
    final rt = s.rt;
    if (rt != null) unawaited(rt.disconnect().catchError((Object _) {}));
  }
}
