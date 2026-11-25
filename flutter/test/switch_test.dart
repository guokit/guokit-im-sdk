// 换号：同一个 GuokitIm 里 A 登出、B 登录，A 的在途请求与回调不能落到 B 身上。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guokit_im/guokit_im.dart';
import 'package:guokit_im/src/store_sqlite.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fakes.dart';

http.Response _res(Object data, {int status = 200, Object code = 0}) =>
    http.Response(
      jsonEncode({'code': code, 'message': 'ok', 'data': data}),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _conv(int id, String peer) => {
  'conversation_id': id,
  'type': 'c2c',
  'peer': {'user_id': peer, 'nickname': '', 'avatar_url': ''},
  'last_message': null,
  'unread': 1,
  'max_seq': 1,
  'read_seq': 0,
  'last_msg_at': '2026-11-20 10:00:00',
};

void main() {
  sqfliteFfiInit();
  late GuokitIm im;
  late ImStore store;
  late Future<ImToken> Function() provider;
  late Future<http.Response> Function(http.Request) handler;
  late List<FakeRealtime> rts;
  var user = 'A';

  Future<http.Response> base(http.Request r) async =>
      _res({'items': <Object>[], 'next_cursor': '', 'has_more': false});

  void create(ImStore s) {
    store = s;
    user = 'A';
    rts = [];
    handler = base;
    provider = () async => ImToken('tok-$user', DateTime.utc(2099));
    im = GuokitIm(
      ImConfig(
        baseUrl: 'https://x',
        store: store,
        tokenProvider: () => provider(),
        realtimeFactory: (u, t) {
          final rt = FakeRealtime(t);
          rts.add(rt);
          return rt;
        },
        httpClient: MockClient((r) => handler(r)),
      ),
    );
  }

  setUp(() => create(MemoryImStore()));
  tearDown(() => im.dispose());

  Future<void> switchToB() async {
    await im.logout();
    user = 'B';
    await im.login('B');
    await pumpEventQueue();
  }

  test('A 在途的发送遇 401：不换令牌重发，返回失败且不发事件', () async {
    final gate = Completer<void>();
    final posts = <String>[];
    handler = (r) async {
      if (r.method != 'POST' || !r.url.path.endsWith('/messages')) {
        return base(r);
      }
      posts.add(r.headers['Authorization']!);
      await gate.future;
      return _res({}, status: 401, code: 'IM_TOKEN_INVALID');
    };
    await im.login('A');
    await pumpEventQueue();
    final sending = im.sendText('peer', 'A 写的');
    await pumpEventQueue();
    await switchToB();
    final updated = <ImMessage>[];
    im.onMessageUpdated.listen(updated.add);
    gate.complete();
    final m = await sending;
    await pumpEventQueue();
    expect(posts, ['Bearer tok-A']);
    expect((m.status, m.errorCode), (ImMessageStatus.failed, 'UNKNOWN'));
    expect(updated, isEmpty);
    expect(await im.pendingTo('peer'), isEmpty);
  });

  for (final sqlite in [false, true]) {
    test('A 迟到的会话列表与消息不进 B 的${sqlite ? ' SQLite ' : '内存'}库', () async {
      if (sqlite) {
        final dir = Directory.systemTemp.createTempSync('guokit_im_switch');
        addTearDown(() => dir.deleteSync(recursive: true));
        create(
          SqliteImStore(
            factory: databaseFactoryFfi,
            directory: () async => dir.path,
          ),
        );
      }
      final gate = Completer<void>();
      handler = (r) async {
        final mine = r.headers['Authorization'] == 'Bearer tok-A';
        if (mine && r.url.path.endsWith('/conversations')) {
          await gate.future;
          return _res({
            'items': [_conv(1, 'friend-of-A')],
            'next_cursor': '',
          });
        }
        if (mine && r.url.path.endsWith('/conversations/1/messages')) {
          await gate.future;
          return _res({'items': <Object>[], 'has_more': false});
        }
        return base(r);
      };
      await im.login('A');
      await pumpEventQueue();
      final loading = expectLater(im.messages(1), throwsStateError);
      await pumpEventQueue();
      await switchToB();
      gate.complete();
      await loading;
      await pumpEventQueue();
      expect(store.userId, 'B');
      expect(await im.conversations(), isEmpty);
      expect(im.totalUnread, 0);
    });
  }

  test('A 迟到的被踢不影响 B；B 自己的照常走', () async {
    handler = (r) async => r.url.path.endsWith('/me')
        ? _res({}, status: 401, code: 'IM_TOKEN_INVALID')
        : base(r);
    var kicked = 0;
    im.onKickedOut.listen((_) => kicked++);
    await im.login('A');
    await pumpEventQueue();
    final late = Completer<ImToken>();
    provider = () => late.future;
    final waiting = expectLater(im.features(), throwsStateError);
    await pumpEventQueue();
    provider = () async => ImToken('tok-$user', DateTime.utc(2099));
    await switchToB();
    late.completeError(const ImKickedOutException());
    await waiting;
    rts.first.emit(const ImRealtimeDisconnected(3503, 'kicked'));
    await pumpEventQueue();
    expect((kicked, im.currentUserId), (0, 'B'));
    expect(im.connectionState, ImConnectionState.connected);
    rts.last.emit(const ImRealtimeDisconnected(3503, 'kicked'));
    await pumpEventQueue();
    expect((kicked, im.connectionState), (1, ImConnectionState.disconnected));
  });

  test('没等登出完就登录：新账号的库不会被旧登出关掉', () async {
    await im.login('A');
    await pumpEventQueue();
    unawaited(im.logout());
    user = 'B';
    await im.login('B');
    await pumpEventQueue();
    expect((store.userId, im.currentUserId), ('B', 'B'));
    expect(im.connectionState, ImConnectionState.connected);
    expect(await im.conversations(), isEmpty);
  });

  test('取令牌卡住时登出再登录同一用户，不会等在旧的登录上', () async {
    final hung = Completer<ImToken>();
    provider = () => hung.future;
    unawaited(im.login('A'));
    await pumpEventQueue();
    await im.logout();
    provider = () async => ImToken('tok-2', DateTime.utc(2099));
    await im.login('A');
    expect(im.connectionState, ImConnectionState.connected);
  });

  for (final delay in [0, 20, 60]) {
    test('两次不同用户的登录重叠（晚 $delay ms）：最终是后一个，库、令牌、连接都是它的', () async {
      final dir = Directory.systemTemp.createTempSync('guokit_im_switch');
      addTearDown(() => dir.deleteSync(recursive: true));
      SqliteImStore sqlite() => SqliteImStore(
        factory: databaseFactoryFfi,
        directory: () async => dir.path,
      );
      final old = sqlite(); // B 在本机登录过，开库比新建的 A 快
      await old.open('B');
      await old.close();
      create(sqlite());
      handler = (r) async => r.url.path.endsWith('/conversations')
          ? _res({
              'items': [_conv(1, 'friend-of-${r.headers['Authorization']}')],
              'next_cursor': '',
            })
          : base(r);
      user = 'X';
      await im.login('X');
      await pumpEventQueue();
      rts.first.closeDelay = const Duration(milliseconds: 40);
      user = 'A';
      final a = im.login('A');
      await Future<void>.delayed(Duration(milliseconds: delay));
      user = 'B';
      await Future.wait([a, im.login('B')]);
      await pumpEventQueue();
      await im.idle;
      expect((im.currentUserId, store.userId), ('B', 'B'));
      expect(im.connectionState, ImConnectionState.connected);
      expect((await im.conversations()).map((c) => c.peer.userId), [
        'friend-of-Bearer tok-B',
      ]);
      expect(rts.where((r) => !r.closed), [rts.last]);
      await im.logout();
      final check = sqlite();
      await check.open('A');
      expect(
        (await check.listConversations()).map((c) => c.peer.userId),
        isNot(contains('friend-of-Bearer tok-B')),
      );
      await check.close();
    });
  }

  test('登录还没完成就登出：不会登录上，状态停在断开', () async {
    final l = im.login('A');
    await im.logout();
    await l;
    await pumpEventQueue();
    expect((im.currentUserId, store.userId), (null, null));
    expect(im.connectionState, ImConnectionState.disconnected);
  });

  test('登出没完又要清缓存：照样清', () async {
    handler = (r) async => r.url.path.endsWith('/conversations')
        ? _res({
            'items': [_conv(1, 'p')],
            'next_cursor': '',
          })
        : base(r);
    await im.login('A');
    await pumpEventQueue();
    unawaited(im.logout());
    await im.logout(clearCache: true);
    await store.open('A');
    expect(await store.listConversations(), isEmpty);
  });

  test('A 的失败消息不能在 B 里重发', () async {
    handler = (r) async => r.url.path.endsWith('/messages')
        ? throw http.ClientException('断网')
        : base(r);
    await im.login('A');
    await pumpEventQueue();
    final m = await im.sendText('peer', 'A 写的');
    expect(m.status, ImMessageStatus.failed);
    await switchToB();
    await expectLater(im.resend(m), throwsArgumentError);
  });

  test('同一用户并发登录只建一条连接；没登录时拉黑抛 StateError', () async {
    await expectLater(im.block('u2'), throwsStateError);
    await Future.wait([im.login('A'), im.login('A')]);
    await pumpEventQueue();
    expect((rts.length, im.connectionState), (1, ImConnectionState.connected));
  });
}
