import 'dart:convert';

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

Map<String, dynamic> _conv(int id, int maxSeq) => {
  'conversation_id': id,
  'type': 'c2c',
  'peer': {'user_id': 'u9', 'nickname': '', 'avatar_url': ''},
  'last_message': null,
  'unread': maxSeq,
  'max_seq': maxSeq,
  'read_seq': 0,
  'last_msg_at': '2026-11-20 10:00:00',
};

void main() {
  late GuokitIm im;
  late MemoryImStore store;
  late FakeRealtime rt;
  late List<String> requests;
  late Map<int, int> serverMax;
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
          if (m != null) {
            final conv = int.parse(m.group(1)!);
            final after = int.parse(req.url.queryParameters['after_seq']!);
            data = {
              'items': [
                for (var s = after + 1; s <= serverMax[conv]!; s++)
                  _msg(conv, s),
              ],
              'has_more': false,
            };
          } else {
            data = {
              'items': [
                for (final e in serverMax.entries) _conv(e.key, e.value),
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
