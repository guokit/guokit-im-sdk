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

class GuokitIm {
  GuokitIm(this.config) : _store = config.store ?? createDefaultStore() {
    _tokens = TokenManager(config.tokenProvider);
    _api = ImApi(
      baseUrl: config.baseUrl,
      tokens: _tokens,
      client: config.httpClient,
    );
  }

  final ImConfig config;
  final ImStore _store;
  late final TokenManager _tokens;
  late final ImApi _api;

  final _newMessage = StreamController<ImMessage>.broadcast();
  final _messageUpdated = StreamController<ImMessage>.broadcast();
  final _conversations = StreamController<List<ImConversation>>.broadcast();
  final _totalUnreadCtrl = StreamController<int>.broadcast();
  final _connection = StreamController<ImConnectionState>.broadcast();
  final _kickedOut = StreamController<void>.broadcast();

  String? _me;
  int _totalUnread = 0;
  ImConnectionState _state = ImConnectionState.disconnected;

  /// 每次登录 / 登出自增；异步回调发现会话号变了就作废。
  int _session = 0;
  ImSync? _sync;
  ImSender? _sender;
  ImRealtime? _rt;
  StreamSubscription<ImRealtimeEvent>? _rtSub;
  String? _rtToken;
  bool _kicked = false;

  /// 连续 3500 换令牌重连的次数，连上后清零；到上限就停（防止 provider 一直给坏令牌时死循环）。
  int _authRetries = 0;
  static const int _maxAuthRetries = 2;

  // ---------------- 状态与事件 ----------------

  /// 当前登录用户，未登录为 null。
  String? get currentUserId => _me;

  /// 当前总未读（各非免打扰会话 `maxSeq − readSeq` 之和）。
  int get totalUnread => _totalUnread;

  ImConnectionState get connectionState => _state;

  /// 新入库的消息：别人发来的，以及本人在其他设备发出的。本设备发出的不走这里。
  Stream<ImMessage> get onNewMessage => _newMessage.stream;

  /// 本地消息变化：发送中 → 成功 / 失败 / 被拒收；图片换新链接。
  Stream<ImMessage> get onMessageUpdated => _messageUpdated.stream;

  /// 会话列表快照：置顶会话在前（按置顶时间倒序），其余按最后消息时间倒序。
  Stream<List<ImConversation>> get onConversationsChanged =>
      _conversations.stream;

  /// 总未读；登录时先推一次初始值，之后变化才推。
  Stream<int> get onTotalUnreadChanged => _totalUnreadCtrl.stream;

  Stream<ImConnectionState> get onConnectionChanged => _connection.stream;

  /// 被封禁或踢下线。SDK 已停止重连，App 应走登出。
  Stream<void> get onKickedOut => _kickedOut.stream;

  /// 同步队列排空时完成。
  @visibleForTesting
  Future<void> get idle => _sync?.idle ?? Future<void>.value();

  // ---------------- 登录 / 登出 ----------------

  /// 打开该用户本地库 → 推一次本地快照与总未读初始值 → 取令牌 → 连接；连上后自动对账。
  ///
  /// 不等对账完成就返回。取令牌失败不抛异常：provider 抛 [ImKickedOutException] 走 [onKickedOut]，
  /// 抛其他异常报 `disconnected`；本地数据照常可读。已登录同一用户且已断开时再调一次即重连。
  Future<void> login(String userId) async {
    if (_me != null && (_me != userId || _kicked)) await logout();
    if (_me == userId) {
      if (_state == ImConnectionState.disconnected) {
        _authRetries = 0; // App 主动重连，3500 重试次数重新算
        await _connect();
      }
      return;
    }
    _session++;
    _authRetries = 0;
    await _store.open(userId); // 打开失败直接抛，状态保持未登录
    _me = userId;
    _sync = ImSync(
      api: _api,
      store: _store,
      me: userId,
      onNewMessage: _newMessage.add,
      onMessageUpdated: _messageUpdated.add,
      onChanged: _emitSnapshot,
      onError: (e) {
        if (e is ImKickedOutException) _kick();
      },
    );
    _sender = ImSender(
      api: _api,
      store: _store,
      sync: _sync!,
      me: userId,
      onUpdated: _messageUpdated.add,
      onSnapshot: _emitSnapshot,
      onKickedOut: _kick,
    );
    await _emitSnapshot(forceTotal: true);
    await _connect();
  }

  /// 断开、清令牌、关闭本地库。[clearCache] 为 true 时删除该用户本地库。
  Future<void> logout({bool clearCache = false}) async {
    final me = _me;
    if (me == null) return;
    _session++;
    _sync?.close();
    _sync = null;
    _sender = null;
    await _rtSub?.cancel();
    _rtSub = null;
    final rt = _rt;
    _rt = null;
    if (rt != null) {
      try {
        await rt.close();
      } catch (_) {}
    }
    _tokens.clear();
    _rtToken = null;
    if (clearCache) {
      await _store.deleteAll(me);
    } else {
      await _store.close();
    }
    _me = null;
    _kicked = false;
    if (_totalUnread != 0) {
      _totalUnread = 0;
      _totalUnreadCtrl.add(0);
    }
    _setState(ImConnectionState.disconnected);
  }

  /// 登出并关闭全部事件流与 HTTP 客户端，之后不能再用。
  Future<void> dispose() async {
    await logout();
    _api.close();
    for (final c in [
      _newMessage,
      _messageUpdated,
      _conversations,
      _totalUnreadCtrl,
      _connection,
      _kickedOut,
    ]) {
      await c.close();
    }
  }

  // ---------------- 会话与消息 ----------------

  /// 先返回本地快照，同时在后台排一次对账（结果经 [onConversationsChanged] 推出）。
  Future<List<ImConversation>> conversations() async {
    _requireLogin();
    final list = await _store.listConversations();
    unawaited(_sync?.reconcile());
    return list;
  }

  /// 只查本地。null 可能是还没会话，也可能是还没同步到；聊天页照样可以直接发消息。
  Future<ImConversation?> conversationWith(String peerId) {
    _requireLogin();
    return _store.conversationByPeer(peerId);
  }

  /// 发给 [peerId] 的未确认消息（发送中 / 失败 / 被拒收），按 `createdAt` 升序，只查本地。
  ///
  /// 会话建立前第一条消息就发失败时，[conversationWith] 为 null、[messages] 也取不到它；
  /// 聊天页这时调本方法显示这些消息，并可对 failed 的调 [resend]（rejected 不能重发）。已有会话时 [messages] 的最新一页已经附带它们。
  Future<List<ImMessage>> pendingTo(String peerId) async {
    _requireLogin();
    return (await _store.unconfirmedMessages(peerId))
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
  }) => _call(() async {
    _requireLogin();
    final sync = _sync!;
    final beforeSeq = before?.seq;
    // 清空记录后，能看到的第一条是 clearSeq + 1。
    final conv = await _store.getConversation(conversationId);
    final firstSeq = (conv?.clearSeq ?? 0) + 1;

    if (beforeSeq != null) {
      if (beforeSeq <= firstSeq) return <ImMessage>[];
      var local = await _store.messages(
        conversationId,
        beforeSeq: beforeSeq,
        limit: limit,
      );
      if (!_complete(local, limit, firstSeq, beforeSeq: beforeSeq)) {
        final r = await _api.messages(
          conversationId,
          beforeSeq: beforeSeq,
          limit: limit,
        );
        await sync.ingest(conversationId, r.items, notify: false);
        local = await _store.messages(
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
      final r = await _api.messages(conversationId, limit: limit);
      await sync.ingest(conversationId, r.items, notify: false);
      if (r.items.isNotEmpty && await _store.syncedSeq(conversationId) == 0) {
        await _store.setSyncedSeq(
          conversationId,
          (r.items.last['seq'] as num).toInt(),
        );
      }
    }

    final synced = await _store.syncedSeq(conversationId);
    if (synced == 0) {
      await fetchLatest();
    } else if (conv != null && synced < conv.maxSeq) {
      await sync.pullAfter(conversationId, synced, notify: false);
    }
    var local = await _store.messages(conversationId, limit: limit);
    if (!fetched && !_complete(local, limit, firstSeq)) {
      await fetchLatest();
      local = await _store.messages(conversationId, limit: limit);
    }

    final peer = (await _store.getConversation(conversationId))?.peer.userId;
    final pending = peer == null
        ? <ImMessage>[]
        : (await _store.unconfirmedMessages(peer)
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt)));
    if (fetched || pending.isNotEmpty) await _emitSnapshot();
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
  Future<void> markRead(int conversationId) => _call(() async {
    _requireLogin();
    final conv = await _store.getConversation(conversationId);
    if (conv == null || conv.readSeq >= conv.maxSeq) return;
    final r = await _api.markRead(conversationId, conv.maxSeq);
    await _store.setReadSeq(conversationId, r.readSeq);
    await _emitSnapshot();
  });

  /// 一键清全部未读。
  Future<void> markAllRead() => _call(() async {
    _requireLogin();
    await _api.markAllRead();
    await _store.markAllRead();
    await _emitSnapshot();
  });

  /// 置顶 / 取消置顶。超过 50 个、或会话不在列表里（已删除）时抛 [ImApiException]。多端同步。
  Future<void> setPinned(int conversationId, bool pinned) => _change(
    () => _api.setConversationSettings(conversationId, pinned: pinned),
  );

  /// 开 / 关免打扰：会话自己的 `unread` 照常计数，但不计入总未读。多端同步。
  Future<void> setMuted(int conversationId, bool muted) =>
      _change(() => _api.setConversationSettings(conversationId, muted: muted));

  /// 清空本人这一侧的记录：会话留在列表原位，预览为 null、未读为 0。对方与服务端的记录不受影响。
  /// 本设备还没发成功的消息（发送中 / 失败）不清。
  Future<void> clearConversation(int conversationId) =>
      _change(() => _api.clearConversation(conversationId));

  /// 删除会话：从列表消失，并清空本人这一侧的记录（含本设备没发成功的消息）。之后有新消息时会话会重新出现，
  /// 只能看到新消息；客服会话在坐席回复、欢迎语、转接提示、接待超时提示、评价邀请时也会这样重新出现。免打扰设置保留。
  Future<void> deleteConversation(int conversationId) =>
      _change(() => _api.deleteConversation(conversationId));

  /// 调会话设置写接口，返回的设置进同步队列应用到本地（顺带推快照）。
  Future<void> _change(Future<Map<String, dynamic>> Function() request) =>
      _call(() async {
        _requireLogin();
        final sync = _sync!;
        await sync.applySettings(await request());
      });

  Future<void> block(String userId) => _call(() => _api.block(userId));

  Future<void> unblock(String userId) => _call(() => _api.unblock(userId));

  Future<({List<ImBlockItem> items, bool hasMore})> blocks({
    int? offset,
    int? limit,
  }) => _call(() => _api.blocks(offset: offset, limit: limit));

  // ---------------- 客服 ----------------

  /// 当前客服接待状态，用于客服会话页顶部的「排队中，前面还有 N 位」状态条。
  /// 服务端不推送，建议进入客服会话、收到 `@cs` 新消息时各刷新一次。站点没装客服时抛 [ImApiException]。
  Future<ImCsState> csState() => _call(() {
    _requireLogin();
    return _api.csState();
  });

  /// 转人工，返回转完的状态（排队中或坐席接待中）；当前没有机器人接待时什么都不做，返回当前状态。
  /// 需要 IM 服务端 v1.12.0 及以上，旧服务端上抛 [ImApiException]。
  Future<ImCsState> handoffCs() => _call(() {
    _requireLogin();
    return _api.csHandoff();
  });

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
    return _call(() {
      _requireLogin();
      return _api.csRate(sessionId, rating, comment: comment);
    });
  }

  static final _leavePhone = RegExp(r'^[0-9+\- ]{5,30}$');

  /// 没有坐席在时留联系方式，把这次排队立刻转成留言，返回单号。[ImCsState.canLeave] 为 true 时再给用户表单；
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
  /// [ImApiException.isTemporary] 自动重试**。需要 IM 服务端 v1.13.0 及以上。
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
    return _call(() {
      _requireLogin();
      return _api.csLeave(name: n, phone: p, email: e);
    });
  }

  // ---------------- 发送 ----------------
  //
  // 都返回 `Future<ImMessage>`：本地「发送中」消息立即经 [onMessageUpdated] 发出，Future 在终态
  // （sent / failed / rejected）完成。**发送失败不抛异常**，看 `status` 与 `errorCode`（含义见 sender.dart）。
  // 只有未登录（StateError）、参数用错（ArgumentError / UnsupportedError）这类编程错误会抛。

  /// 发文本。
  Future<ImMessage> sendText(String to, String text) =>
      _requireSender().sendText(to, text);

  /// 按文件路径发图（iOS / Android）。Web 上抛 [UnsupportedError]，请用 [sendImageBytes]。
  Future<ImMessage> sendImage(String to, String filePath) =>
      _requireSender().sendImage(to, filePath);

  /// 按字节发图（Web 必须用这个）。
  Future<ImMessage> sendImageBytes(
    String to,
    Uint8List bytes, {
    String filename = 'image.jpg',
  }) => _requireSender().sendImageBytes(to, bytes, filename: filename);

  /// 发位置。
  Future<ImMessage> sendLocation(
    String to,
    double lat,
    double lng, {
    String? name,
    String? address,
  }) =>
      _requireSender().sendLocation(to, lat, lng, name: name, address: address);

  /// 发自定义消息。[data] 必须是 JSON 对象，[desc] 用于会话预览与离线推送文字。
  Future<ImMessage> sendCustom(
    String to,
    Map<String, dynamic> data,
    String desc,
  ) => _requireSender().sendCustom(to, data, desc);

  /// 重发 failed 消息，沿用原 clientMsgId。传入非 failed（含 rejected）抛 [ArgumentError]。
  Future<ImMessage> resend(ImMessage failed) => _requireSender().resend(failed);

  /// 图片可用地址：外链图原样返回；上传图链接过期（取得超过 20 小时或为空）时重拉这条消息，
  /// 更新本地并发 [onMessageUpdated] 后返回新地址；重拉失败返回旧地址。非图片返回 null。
  /// 未确认（发送中 / 失败）的上传图返回上传时拿到的临时链接（约 24 小时有效），按路径发的图优先用 `localPath`。
  Future<String?> imageUrl(ImMessage message) =>
      _requireSender().imageUrl(message);

  // ---------------- 内部 ----------------

  ImSender _requireSender() {
    _requireLogin();
    return _sender!;
  }

  String _requireLogin() {
    final me = _me;
    if (me == null) throw StateError('GuokitIm 未登录');
    return me;
  }

  /// HTTP 调用统一入口：换令牌时 provider 抛 [ImKickedOutException] 先走 [onKickedOut] 再上抛。
  Future<T> _call<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on ImKickedOutException {
      _kick();
      rethrow;
    }
  }

  void _setState(ImConnectionState s) {
    if (_state == s) return;
    _state = s;
    _connection.add(s);
  }

  Future<void> _emitSnapshot({bool forceTotal = false}) async {
    final session = _session;
    if (_me == null) return;
    final list = await _store.listConversations();
    final total = await _store.totalUnread();
    if (session != _session) return;
    _conversations.add(list);
    if (forceTotal || total != _totalUnread) {
      _totalUnread = total;
      _totalUnreadCtrl.add(total);
    }
  }

  Future<void> _connect() async {
    final session = _session;
    _setState(ImConnectionState.connecting);
    final String token;
    try {
      token = await _tokens.current();
    } on ImKickedOutException {
      if (session == _session) _kick();
      return;
    } catch (_) {
      if (session == _session) _setState(ImConnectionState.disconnected);
      return;
    }
    if (session != _session) return;
    var rt = _rt;
    if (rt == null) {
      final factory = config.realtimeFactory ?? CentrifugeRealtime.new;
      rt = _rt = factory(imWebSocketUrl(config.baseUrl), token);
      _rtSub = rt.events.listen((e) => _onRealtime(e, session));
    } else {
      rt.setToken(token);
    }
    _rtToken = token;
    try {
      await rt.connect();
    } catch (_) {
      if (session == _session) _setState(ImConnectionState.disconnected);
    }
  }

  void _onRealtime(ImRealtimeEvent e, int session) {
    if (session != _session || _kicked) return;
    try {
      switch (e) {
        case ImRealtimeConnecting():
          _setState(ImConnectionState.connecting);
        case ImRealtimeConnected():
          _authRetries = 0;
          _setState(ImConnectionState.connected);
          unawaited(_sync?.reconcile());
        case ImRealtimeDisconnected(:final code):
          if (code == 3503) {
            _kick();
          } else if (code == 3500) {
            unawaited(_reauth(session));
          } else {
            _setState(ImConnectionState.disconnected);
          }
        case ImRealtimePublication(:final data):
          unawaited(_sync?.handlePush(data));
      }
    } catch (_) {
      // 事件处理不能抛出去。
    }
  }

  /// 3500：换令牌（单次）后 setToken + connect。3500 不触发 centrifuge 的 getToken，要手动做。
  Future<void> _reauth(int session) async {
    if (_authRetries >= _maxAuthRetries) {
      // 缓存里还是刚被拒的令牌，丢掉它：否则再调 login 时 _connect 会拿它连、又收 3500，
      // 永远不再调 provider。别的请求已换过新令牌时缓存不等于 _rtToken，保留。
      if (_rtToken != null && _tokens.cached?.token == _rtToken) {
        _tokens.clear();
      }
      _setState(ImConnectionState.disconnected);
      return;
    }
    _authRetries++;
    _setState(ImConnectionState.connecting);
    try {
      final t = await _tokens.refresh(stale: _rtToken);
      final rt = _rt;
      if (session != _session || _kicked || rt == null) return;
      _rtToken = t;
      rt.setToken(t);
      await rt.connect();
    } on ImKickedOutException {
      if (session == _session) _kick();
    } catch (_) {
      if (session == _session) _setState(ImConnectionState.disconnected);
    }
  }

  /// 被封 / 被踢：停止重连，不再调 provider，发 [onKickedOut]。本地库保持打开，等 App 调 [logout]。
  void _kick() {
    if (_me == null || _kicked) return;
    _kicked = true;
    _setState(ImConnectionState.disconnected);
    _kickedOut.add(null);
    final rt = _rt;
    if (rt != null) unawaited(rt.disconnect().catchError((Object _) {}));
  }
}
