import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guokit_im/guokit_im.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

http.Response _ok(Object data) => http.Response(
  jsonEncode({'code': 0, 'message': 'ok', 'data': data}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  late GuokitIm im;
  late MemoryImStore store;
  late FakeRealtime rt;
  late List<Map<String, dynamic>> sent; // POST /messages 的请求体
  late Map<String, dynamic> lastServerMsg;
  var mode = 'ok';
  var seq = 0;

  Future<void> settle() async {
    await pumpEventQueue();
    await im.idle;
  }

  setUp(() async {
    sent = [];
    mode = 'ok';
    seq = 0;
    store = MemoryImStore();
    im = GuokitIm(
      ImConfig(
        baseUrl: 'https://im.example.com',
        store: store,
        tokenProvider: () async =>
            ImToken('t', DateTime.now().toUtc().add(const Duration(days: 7))),
        realtimeFactory: (url, token) => rt = FakeRealtime(token),
        httpClient: MockClient((req) async {
          final path = req.url.path;
          if (path.endsWith('/upload')) {
            return _ok({
              'attachment_id': 55,
              'url': 'https://im/preview',
              'ticket': 'tk',
            });
          }
          if (path.endsWith('/messages') && req.method == 'POST') {
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            sent.add(body);
            if (mode == 'network') throw http.ClientException('断网');
            if (mode == 'blocked') {
              return http.Response(
                jsonEncode({
                  'code': 'IM_BLOCKED',
                  'message': '对方已将你拉黑',
                  'data': {},
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            final content = Map<String, dynamic>.from(body['content'] as Map);
            if (content.remove('ticket') != null) {
              content['url'] = 'https://im/old';
            }
            seq++;
            return _ok(
              lastServerMsg = {
                'id': 1000 + seq,
                'conversation_id': 1,
                'seq': seq,
                'from': 'u1',
                'type': body['type'],
                'content': content,
                'client_msg_id': body['client_msg_id'],
                'created_at': '2026-11-20 10:00:00',
              },
            );
          }
          if (path.endsWith('/conversations/1/messages')) {
            final m = Map<String, dynamic>.from(lastServerMsg)
              ..['content'] = {
                ...lastServerMsg['content'] as Map,
                'url': 'https://im/new',
              };
            return _ok({
              'items': [m],
              'has_more': false,
            });
          }
          return _ok({'items': [], 'next_cursor': ''}); // 会话列表
        }),
      ),
    );
    await im.login('u1');
    await settle();
  });

  test('sendText 成功只存一条，同条推送再到仍一条', () async {
    final news = <ImMessage>[];
    im.onNewMessage.listen(news.add);
    final m = await im.sendText('u2', 'hi');
    expect((m.status, m.seq, m.to), (ImMessageStatus.sent, 1, 'u2'));
    rt.emit(
      ImRealtimePublication({
        'event': 'message',
        'conversation_id': 1,
        'seq': 1,
        'message': lastServerMsg,
      }),
    );
    await settle();
    expect((await store.messages(1)).length, 1);
    expect(await store.unconfirmedMessages('u2'), isEmpty);
    expect(news, isEmpty);
    expect((await im.conversationWith('u2'))!.lastMessage!.preview, 'hi');
  });

  test(
    '网络失败 → failed → resend 沿用原 clientMsgId 后 sent；IM_BLOCKED → rejected',
    () async {
      mode = 'network';
      final failed = await im.sendText('u2', 'hi');
      expect(
        (failed.status, failed.errorCode),
        (ImMessageStatus.failed, 'NETWORK'),
      );
      mode = 'ok';
      final ok = await im.resend(failed);
      expect(
        (ok.status, ok.clientMsgId),
        (ImMessageStatus.sent, failed.clientMsgId),
      );
      expect(sent.map((b) => b['client_msg_id']).toSet().length, 1);

      mode = 'blocked';
      final r = await im.sendText('u2', 'again');
      expect((r.status, r.errorCode), (ImMessageStatus.rejected, 'IM_BLOCKED'));
      expect(() => im.resend(r), throwsArgumentError);
    },
  );

  test('sendImageBytes 上传后发送；链接超过 20 小时 imageUrl 重拉', () async {
    final m = await im.sendImageBytes('u2', _png, filename: 'a.png');
    expect(m.status, ImMessageStatus.sent);
    expect(sent.single['content'], {
      'attachment_id': 55,
      'ticket': 'tk',
      'width': 1,
      'height': 1,
    });
    expect(await im.imageUrl(m), 'https://im/old');

    await store.upsertMessage(
      m.copyWith(
        urlFetchedAt: DateTime.now().toUtc().subtract(
          const Duration(hours: 21),
        ),
      ),
    );
    expect(await im.imageUrl(m), 'https://im/new');
  });

  test('sendVoiceBytes 上传后发送带时长；时长越界抛 ArgumentError', () async {
    final m = await im.sendVoiceBytes(
      'u2',
      _png,
      const Duration(milliseconds: 2600),
    );
    expect(m.status, ImMessageStatus.sent);
    expect(sent.single['content'], {
      'attachment_id': 55,
      'ticket': 'tk',
      'duration': 3,
    });
    expect(m.voiceDuration, const Duration(seconds: 3));
    expect(await im.voiceUrl(m), 'https://im/old');
    expect(await im.imageUrl(m), null);
    expect((await im.conversationWith('u2'))!.lastMessage!.preview, '[语音]');
    expect(
      () => im.sendVoiceBytes('u2', _png, const Duration(seconds: 61)),
      throwsArgumentError,
    );
  });

  test('语音网络失败后重发：不丢时长', () async {
    mode = 'network';
    final f = await im.sendVoiceBytes('u2', _png, const Duration(seconds: 5));
    expect(f.status, ImMessageStatus.failed);
    mode = 'ok';
    final ok = await im.resend(f);
    expect(ok.status, ImMessageStatus.sent);
    expect((sent.last['content'] as Map)['duration'], 5);
  });
}
