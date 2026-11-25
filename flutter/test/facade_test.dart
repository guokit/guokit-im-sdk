import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:guokit_im/guokit_im.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

Map<String, dynamic> _msg(int conv, int seq) => {
  'id': conv * 100 + seq,
  'conversation_id': conv,
  'seq': seq,
  'from': 'u9',
  'type': 'text',
  'content': {'text': 's$seq'},
  'client_msg_id': 'c$conv-$seq',
  'created_at': '2026-11-20 10:00:00',
};

Map<String, dynamic> _conv(
  int id,
  int maxSeq, {
  int clearSeq = 0,
  Map<String, dynamic>? settings,
}) => {
  'conversation_id': id,
  'type': 'c2c',
  'peer': {'user_id': 'u9', 'nickname': '', 'avatar_url': ''},
  'last_message': maxSeq <= clearSeq
      ? null
      : {
          'seq': maxSeq,
          'from': 'u9',
          'type': 'text',
          'preview': 's$maxSeq',
          'created_at': '2026-11-20 10:00:00',
        },
  'unread': maxSeq - clearSeq,
  'max_seq': maxSeq,
  'read_seq': clearSeq,
  'last_msg_at': '2026-11-20 10:00:00',
  'clear_seq': clearSeq,
  'pinned': settings?['pinned_at'] != null,
  'pinned_at': settings?['pinned_at'],
  'muted': settings?['muted'] ?? false,
};

Map<String, dynamic> _recalled(int conv, int seq) => {
  ..._msg(conv, seq),
  'type': 'recalled',
  'content': {'by': 'sender'},
};

void main() {
  late GuokitIm im;
  late MemoryImStore store;
  late FakeRealtime rt;
  late List<String> requests;
  var leaveBody = '';

  // 服务端的撤回增量（cursor 固定为 'r1'，每次都重复给全部）。
  late List<Map<String, dynamic>> recalled;
  late Map<int, int> serverMax;

  // 服务端的会话设置：changed 里有的会话会出现在 changes 里（cursor 固定为 'k1'）。
  late Map<int, Map<String, dynamic>> changed;

  /// 非空时拉消息算好结果后等它放行，模拟响应晚到。
  Completer<void>? gate;
  Map<String, dynamic> settingsOf(int id) => changed[id] ??= {
    'conversation_id': id,
    'peer_user_id': 'u9',
    'pinned': false,
    'pinned_at': null,
    'muted': false,
    'clear_seq': 0,
    'unread': 0,
    'visible': true,
  };
  int clearOf(int id) => (changed[id]?['clear_seq'] as int?) ?? 0;
  void serverClear(int id, {bool del = false}) {
    settingsOf(id)['clear_seq'] = serverMax[id];
    if (del) settingsOf(id).addAll({'visible': false, 'pinned_at': null});
  }

  void pushMessage(int conv, int seq) {
    serverMax[conv] = seq;
    changed[conv]?['visible'] = true;
    rt.emit(
      ImRealtimePublication({
        'event': 'message',
        'conversation_id': conv,
        'seq': seq,
        'message': _msg(conv, seq),
      }),
    );
  }

  var providerCalls = 0;
  Object? providerError;

  Future<void> settle() async {
    for (var i = 0; i < 3; i++) {
      await pumpEventQueue();
      await im.idle;
    }
  }

  setUp(() async {
    requests = [];
    serverMax = {1: 5, 2: 4};
    changed = {};
    recalled = [];
    gate = null;
    providerCalls = 0;
    providerError = null;
    // 本地：会话 1 拉过消息（syncedSeq = 2），会话 2 从没拉过。
    store = MemoryImStore();
    await store.open('u1');
    await store.upsertConversations([
      ImConversation.fromServer(_conv(1, 2)),
      ImConversation.fromServer(_conv(2, 1)),
    ]);
    await store.upsertMessages([
      for (final s in [1, 2]) ImMessage.fromServer(_msg(1, s), me: 'u1'),
    ]);
    await store.setSyncedSeq(1, 2);
    await store.close();

    im = GuokitIm(
      ImConfig(
        baseUrl: 'https://im.example.com',
        store: store,
        tokenProvider: () async {
          providerCalls++;
          if (providerError != null) throw providerError!;
          return ImToken(
            't$providerCalls',
            DateTime.now().toUtc().add(const Duration(days: 7)),
          );
        },
        realtimeFactory: (url, token) {
          expect(url, 'wss://im.example.com/api/im/v1/connect/websocket');
          return rt = FakeRealtime(token);
        },
        httpClient: MockClient((req) async {
          requests.add('${req.url.path}?${req.url.query}');
          final m = RegExp(
            r'/conversations/(\d+)/messages',
          ).firstMatch(req.url.path);
          Object data;
          if (req.url.path.endsWith('/leave')) {
            leaveBody = req.body;
            data = {'ticket_no': 'T1'};
          } else if (m != null) {
            final conv = int.parse(m.group(1)!);
            final q = req.url.queryParameters;
            final floor = max(clearOf(conv), int.parse(q['after_seq'] ?? '0'));
            final end = q['before_seq'] == null
                ? serverMax[conv]!
                : int.parse(q['before_seq']!) - 1;
            data = {
              'items': [for (var s = floor + 1; s <= end; s++) _msg(conv, s)],
              'has_more': false,
            };
            await gate?.future;
          } else if (req.url.path.endsWith('/recalls')) {
            data = {
              'items': [
                for (final m in recalled)
                  {
                    'conversation_id': m['conversation_id'],
                    'message_id': m['id'],
                    'seq': m['seq'],
                    'message': m,
                  },
              ],
              'next_cursor': recalled.isEmpty ? '' : 'r1',
              'has_more': false,
            };
          } else if (req.url.path.endsWith('/recall')) {
            data = {..._recalled(1, 5), 'from': 'u1'};
          } else if (req.url.path.endsWith('/typing')) {
            data = <String, dynamic>{};
          } else if (req.url.path.endsWith('/read')) {
            data = {'read_seq': serverMax[1], 'unread': 0};
          } else if (req.url.path.endsWith('/changes')) {
            data = {
              'items': changed.values.toList(),
              'next_cursor': changed.isEmpty ? '' : 'k1',
              'has_more': false,
            };
          } else if (req.method != 'GET') {
            final id = int.parse(
              RegExp(
                r'/conversations/(\d+)',
              ).firstMatch(req.url.path)!.group(1)!,
            );
            if (req.method == 'PUT') {
              final body = jsonDecode(req.body) as Map;
              settingsOf(id).addAll({
                if (body.containsKey('muted')) 'muted': body['muted'],
                if (body.containsKey('pinned'))
                  'pinned_at': body['pinned'] == true
                      ? '2026-11-24 10:00:00'
                      : null,
              });
            } else {
              serverClear(id, del: req.method == 'DELETE');
            }
            data = settingsOf(id);
          } else {
            data = {
              'items': [
                for (final e in serverMax.entries)
                  if (changed[e.key]?['visible'] != false)
                    _conv(
                      e.key,
                      e.value,
                      clearSeq: clearOf(e.key),
                      settings: changed[e.key],
                    ),
              ],
              'next_cursor': '',
            };
          }
          return http.Response(
            jsonEncode({'code': 0, 'message': 'ok', 'data': data}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    );
  });

  test('对账只补拉 syncedSeq > 0 的会话；推送跳号先补拉', () async {
    final news = <int>[];
    im.onNewMessage.listen((m) => news.add(m.seq!));
    await im.login('u1');
    await settle();
    expect(requests.where((r) => r.contains('/messages')), [
      '/api/im/v1/conversations/1/messages?after_seq=2&limit=100',
    ]);
    expect(await store.syncedSeq(1), 5);
    expect(im.totalUnread, 9);

    serverMax[1] = 8;
    news.clear();
    rt.emit(
      ImRealtimePublication({
        'event': 'message',
        'conversation_id': 1,
        'seq': 8,
        'message': _msg(1, 8),
      }),
    );
    await settle();
    expect(
      requests.last,
      '/api/im/v1/conversations/1/messages?after_seq=5&limit=100',
    );
    expect(news, [6, 7, 8]);
    expect(await store.syncedSeq(1), 8);
  });

  test('落后设备遇到清空：旧消息清掉、不反复补拉，之后只看到新消息', () async {
    serverClear(1);
    final news = <int>[];
    im.onNewMessage.listen((m) => news.add(m.seq!));
    await im.login('u1');
    await settle();
    await im.conversations();
    await settle();
    expect(requests.where((r) => r.contains('/messages')), isEmpty);
    expect(
      requests.lastWhere((r) => r.contains('/changes')),
      contains('cursor=k1'),
    );
    final c = (await store.getConversation(1))!;
    expect((c.clearSeq, c.unread, c.lastMessage), (5, 0, null));
    expect(await store.messages(1), isEmpty);
    expect(await store.syncedSeq(1), 5);

    // 清空前发出、清空后才到的推送丢弃
    rt.emit(
      ImRealtimePublication({
        'event': 'message',
        'conversation_id': 1,
        'seq': 4,
        'message': _msg(1, 4),
      }),
    );
    pushMessage(1, 6);
    await settle();
    expect(news, [6]);
    final page = await im.messages(1);
    expect(page.map((m) => m.seq), [6]);
    final before = requests.length;
    expect(await im.messages(1, before: page.first), isEmpty);
    expect(requests.length, before);
  });

  test('撤回：离线补齐只更新本地已有的，推送替换消息与预览，重复给不重复发事件', () async {
    final updated = <int>[];
    final news = <int>[];
    im.onMessageUpdated.listen((m) => updated.add(m.seq!));
    im.onNewMessage.listen((m) => news.add(m.seq!));
    // 1/2 本地有；2/4 本地没有消息行、但它是会话 2 的预览
    recalled = [_recalled(1, 2), _recalled(2, 4), _recalled(9, 1)];
    await im.login('u1');
    await settle();
    expect(updated, [2]);
    expect((await store.getMessageById(102))!.isRecalled, true);
    expect(await store.getMessageById(204), null);
    expect((await store.getConversation(2))!.lastMessage!.preview, '[消息已撤回]');
    expect(await store.getConversation(9), null);
    expect(await store.recallsCursor(), 'r1');

    rt.emit(const ImRealtimeConnected()); // 重连再对一次账
    await settle();
    expect(updated, [2]);

    updated.clear();
    news.clear();
    final push = ImRealtimePublication({
      'event': 'message_recalled',
      'conversation_id': 1,
      'seq': 5,
      'message': _recalled(1, 5),
    });
    rt.emit(push);
    rt.emit(push);
    rt.emit(
      ImRealtimePublication({
        'event': 'message_recalled',
        'conversation_id': 77,
        'seq': 1,
        'message': _recalled(77, 1),
      }),
    );
    await settle();
    expect(updated, [5]);
    expect(news, isEmpty);
    expect((await store.getConversation(1))!.lastMessage!.preview, '[消息已撤回]');
    expect(await store.getConversation(77), null); // 本地没有的会话不因撤回建出来

    // 已被本人清空的消息之后被撤回：不入库、不发事件
    await im.clearConversation(1);
    await settle();
    updated.clear();
    rt.emit(
      ImRealtimePublication({
        'event': 'message_recalled',
        'conversation_id': 1,
        'seq': 4,
        'message': _recalled(1, 4),
      }),
    );
    await settle();
    expect(updated, isEmpty);
  });

  test('recall 走同步队列替换本地；别人的或未发出的抛 ArgumentError', () async {
    await im.login('u1');
    await settle();
    await store.upsertMessage(
      ImMessage.fromServer({..._msg(1, 5), 'from': 'u1'}, me: 'u1'),
    );
    final mine = (await store.getMessageById(105))!;
    await im.recall(mine);
    expect(requests.last, contains('/messages/105/recall'));
    expect((await store.getMessageById(105))!.isRecalled, true);
    expect(
      () => im.recall(ImMessage.fromServer(_msg(1, 4), me: 'u1')),
      throwsArgumentError,
    );
  });

  test('对方已读推送；一键清未读之后打开聊天仍要标已读', () async {
    await im.login('u1');
    await settle();
    rt.emit(
      const ImRealtimePublication({
        'event': 'peer_read',
        'conversation_id': 1,
        'peer_read_seq': 3,
      }),
    );
    await settle();
    expect((await store.getConversation(1))!.peerReadSeq, 3);

    await store.markAllRead();
    for (var i = 0; i < 2; i++) {
      await im.markRead(1);
    }
    expect(
      requests.where((r) => r.contains('/conversations/1/read')).length,
      1,
    );
  });

  test('正在输入：推送即时给出、收到消息收起；发送按会话 3 秒节流', () async {
    final got = <(int, bool)>[];
    im.onTyping.listen((t) => got.add((t.conversationId, t.active)));
    await im.login('u1');
    await settle();
    rt.emit(
      const ImRealtimePublication({
        'event': 'typing',
        'conversation_id': 1,
        'from': 'u9',
        'expires_in': 6,
      }),
    );
    await settle();
    pushMessage(1, 6);
    await settle();
    expect(got, [(1, true), (1, false)]);

    await im.sendTyping(1);
    await im.sendTyping(1);
    await im.sendTyping(2);
    expect(requests.where((r) => r.contains('/typing')).length, 2);
    await im.logout();
  });

  test('删除会话：会话与消息都没了；新消息让它重新出现，旧消息不复现', () async {
    await im.login('u1');
    await settle();
    // 删除前发出、删除后才返回的拉消息结果不把会话又建出来
    gate = Completer();
    final stale = im.messages(2);
    await pumpEventQueue();
    await im.deleteConversation(2);
    gate!.complete();
    expect(await stale, isEmpty);
    expect((await store.listConversations()).map((c) => c.id), [1]);

    // 别的设备离线期间删的，靠 changes 补上
    serverClear(1, del: true);
    await im.conversations();
    await settle();
    expect(await store.listConversations(), isEmpty);
    expect(await store.messages(1), isEmpty);

    pushMessage(1, 6);
    await settle();
    expect((await store.getConversation(1))!.clearSeq, 5);
    expect((await im.messages(1)).map((m) => m.seq), [6]);

    // 晚到的删除结果不把重新出现的会话又删掉
    rt.emit(
      ImRealtimePublication({
        'event': 'conversation_changed',
        'action': 'delete',
        'conversation': {...settingsOf(1), 'visible': false},
      }),
    );
    await settle();
    expect((await store.messages(1)).map((m) => m.seq), [6]);
  });

  test('setPinned / setMuted 改本地排序与总未读；别的设备的推送覆盖本地设置', () async {
    await im.login('u1');
    await settle();
    expect((await store.listConversations()).map((c) => c.id), [2, 1]);
    await im.setPinned(1, true);
    await im.setMuted(2, true);
    expect((await store.listConversations()).map((c) => c.id), [1, 2]);
    expect(im.totalUnread, 5);
    rt.emit(
      ImRealtimePublication({
        'event': 'conversation_changed',
        'action': 'settings',
        'conversation': {...settingsOf(2), 'muted': false},
      }),
    );
    await settle();
    expect(im.totalUnread, 9);
  });

  test('3503 发 onKickedOut，之后不再连接也不调 provider', () async {
    var kicked = 0;
    im.onKickedOut.listen((_) => kicked++);
    await im.login('u1');
    await settle();
    rt.emit(const ImRealtimeDisconnected(3503, 'kicked'));
    rt.emit(const ImRealtimeDisconnected(3500, 'token'));
    await settle();
    expect(
      (kicked, rt.connects, providerCalls, im.connectionState),
      (1, 1, 1, ImConnectionState.disconnected),
    );
  });

  test(
    '3500 换令牌（provider 只调一次）后重连；provider 抛 ImKickedOutException 走 onKickedOut',
    () async {
      var kicked = 0;
      im.onKickedOut.listen((_) => kicked++);
      await im.login('u1');
      await settle();
      rt.emit(const ImRealtimeDisconnected(3500, 'token'));
      await settle();
      expect(rt.tokens, ['t1', 't2']);
      expect((providerCalls, rt.connects), (2, 2));
      expect(im.connectionState, ImConnectionState.connected);

      providerError = const ImKickedOutException();
      rt.emit(const ImRealtimeDisconnected(3500, 'token'));
      await settle();
      expect((kicked, rt.connects), (1, 2));
    },
  );

  test('rateCs 评分越界、评语超 200 字直接抛 ArgumentError，不发请求', () async {
    await im.login('u1');
    final before = requests.length;
    expect(() => im.rateCs(1, 6), throwsArgumentError);
    expect(() => im.rateCs(1, 5, comment: '字' * 201), throwsArgumentError);
    expect(requests.length, before);
  });

  test('leaveCs 去空白后提交并返回单号；不合要求直接抛 ArgumentError，不发请求', () async {
    await im.login('u1');
    expect(await im.leaveCs(name: ' 张三 ', phone: ' 138 0000 0000 '), 'T1');
    expect(jsonDecode(leaveBody), {
      'contact_name': '张三',
      'contact_phone': '138 0000 0000',
    });
    final before = requests.length;
    expect(() => im.leaveCs(name: '张三', phone: ' '), throwsArgumentError);
    expect(() => im.leaveCs(phone: '12a45'), throwsArgumentError);
    expect(() => im.leaveCs(phone: '1234'), throwsArgumentError);
    expect(
      () => im.leaveCs(name: '字' * 51, phone: '13800000000'),
      throwsArgumentError,
    );
    expect(() => im.leaveCs(email: '${'a' * 120}@b.cn'), throwsArgumentError);
    expect(requests.length, before);
  });

  test('pendingTo：还没有会话时也能取到发给对方的失败消息，按时间升序', () async {
    await im.login('u1');
    ImMessage local(String c, int sec) => ImMessage(
      clientMsgId: c,
      from: 'u1',
      to: 'u7',
      isSelf: true,
      type: 'text',
      content: {'text': c},
      status: ImMessageStatus.failed,
      createdAt: DateTime.utc(2026, 11, 23, 10, 0, sec),
    );
    await store.upsertMessage(local('b', 2));
    await store.upsertMessage(local('a', 1));
    expect(await im.conversationWith('u7'), isNull);
    expect((await im.pendingTo('u7')).map((m) => m.clientMsgId), ['a', 'b']);
    expect(await im.pendingTo('u9'), isEmpty);
  });

  test('3500 重试用完后再调 login(同一用户) 会重新取令牌并连上', () async {
    await im.login('u1');
    await settle();
    rt.badTokens.addAll(['t1', 't2', 't3']);
    rt.emit(const ImRealtimeDisconnected(3500, 'token'));
    await settle();
    expect(
      (providerCalls, im.connectionState),
      (3, ImConnectionState.disconnected),
    );

    await im.login('u1');
    await settle();
    expect(rt.tokens.last, 't4');
    expect(
      (providerCalls, im.connectionState),
      (4, ImConnectionState.connected),
    );
  });
}
