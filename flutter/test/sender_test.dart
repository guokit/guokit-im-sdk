import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

http.Response _error(String code, int status) => http.Response(
  jsonEncode({'code': code, 'message': '不行', 'data': {}}),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

({String kind, String name, int size}) _parseUpload(http.Request req) {
  final body = latin1.decode(req.bodyBytes);
  final kind = RegExp(
    r'name="kind"\r\n\r\n(\w+)\r\n',
  ).firstMatch(body)!.group(1)!;
  final file = RegExp(
    r'name="file"; filename="([^"]*)"\r\n\r\n',
  ).firstMatch(body)!;
  return (
    kind: kind,
    name: utf8.decode(latin1.encode(file.group(1)!)),
    size: body.lastIndexOf('\r\n--') - file.end,
  );
}

void main() {
  late GuokitIm im;
  late MemoryImStore store;
  late FakeRealtime rt;
  late List<Map<String, dynamic>> sent; // POST /messages 的请求体
  late Map<String, dynamic> lastServerMsg;
  // POST /upload 的请求：类型、文件名、请求体里的文件字节数；返回非 null 即以它作响应。
  late List<({String kind, String name, int size})> uploads;
  http.Response? Function(String kind)? onUpload;
  var mode = 'ok';
  var seq = 0;

  Future<void> settle() async {
    await pumpEventQueue();
    await im.idle;
  }

  setUp(() async {
    sent = [];
    uploads = [];
    onUpload = null;
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
            final up = _parseUpload(req);
            uploads.add(up);
            final early = onUpload?.call(up.kind);
            if (early != null) return early;
            return _ok({
              'attachment_id': up.name == 'cover.jpg' ? 66 : 55,
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
            if (body['type'] == 'file' || body['type'] == 'video') {
              content['size'] = 2048;
            }
            if (body['type'] == 'video') {
              content['cover_url'] = content.remove('cover_ticket') == null
                  ? ''
                  : 'https://im/cover-old';
              content['cover_attachment_id'] ??= 0;
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

  group('文件与视频', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('guokit_im'));
    tearDown(() => dir.deleteSync(recursive: true));

    String file(String name, [int size = 200000]) {
      final f = File('${dir.path}/$name')..writeAsBytesSync(Uint8List(size));
      return f.path;
    }

    Future<ImMessage> video({Uint8List? cover}) => im.sendVideo(
      'u2',
      file('a.mov'),
      duration: const Duration(milliseconds: 12600),
      width: 1080,
      height: 1920,
      coverBytes: cover,
    );

    // 杀掉进程再进来：本地库还在，内存里的字节没了。
    Future<void> relogin() async {
      await im.logout();
      await im.login('u1');
      await settle();
    }

    test('sendFile 边读边传：报进度，发送只带三个键', () async {
      final progress = <ImSendProgress>[];
      im.onSendProgress.listen(progress.add);
      final m = await im.sendFile('u2', file('合同.pdf'));
      await settle();
      expect((m.status, m.fileName), (ImMessageStatus.sent, '合同.pdf'));
      expect(m.fileSize, 2048);
      expect(uploads.single, (kind: 'file', name: '合同.pdf', size: 200000));
      expect(sent.single['content'], {
        'attachment_id': 55,
        'ticket': 'tk',
        'name': '合同.pdf',
      });
      expect(progress.length, greaterThan(1));
      expect(progress.first.sent, lessThan(200000));
      expect(
        (progress.last.sent, progress.last.total, progress.last.clientMsgId),
        (200000, 200000, m.clientMsgId),
      );
      expect(await im.fileUrl(m), 'https://im/old');
      expect(await im.videoUrl(m), null);
      expect(
        (await im.conversationWith('u2'))!.lastMessage!.preview,
        '[文件] 合同.pdf',
      );
    });

    test('换令牌重传：重新开流，内容完整', () async {
      var n = 0;
      onUpload = (_) => n++ == 0 ? _error('IM_TOKEN_INVALID', 401) : null;
      final m = await im.sendFile('u2', file('a.zip'), name: '资料.zip');
      expect(m.status, ImMessageStatus.sent);
      expect(uploads.map((u) => u.size), [200000, 200000]);
      expect(uploads.last.name, '资料.zip');
    });

    test('传完后发送失败：重发不再上传', () async {
      mode = 'network';
      final f = await im.sendFileBytes('u2', Uint8List(10), name: 'a.txt');
      expect((f.status, f.fileSize), (ImMessageStatus.failed, 10));
      mode = 'ok';
      expect((await im.resend(f)).status, ImMessageStatus.sent);
      expect(uploads.length, 1);
    });

    test('内容已不在：FILE_MISSING / VIDEO_MISSING / FILE_READ', () async {
      onUpload = (_) => throw http.ClientException('断网');
      final f = await im.sendFileBytes('u2', Uint8List(10), name: 'a.txt');
      final v = await im.sendVideoBytes(
        'u2',
        Uint8List(10),
        duration: const Duration(seconds: 1),
        width: 1,
        height: 1,
      );
      await relogin();
      expect((await im.resend(f)).errorCode, 'FILE_MISSING');
      expect((await im.resend(v)).errorCode, 'VIDEO_MISSING');
      final gone = await im.sendFile('u2', '${dir.path}/没有.pdf');
      expect(gone.errorCode, 'FILE_READ');
    });

    test('视频带封面：封面先传；取封面地址，过期重拉', () async {
      final m = await video(cover: _png);
      expect(m.status, ImMessageStatus.sent);
      expect(uploads.map((u) => u.kind), ['image', 'video']);
      expect(sent.single['content'], {
        'attachment_id': 55,
        'ticket': 'tk',
        'duration': 13,
        'width': 1080,
        'height': 1920,
        'cover_attachment_id': 66,
        'cover_ticket': 'tk',
      });
      expect(m.videoDuration, const Duration(seconds: 13));
      expect(await im.videoUrl(m), 'https://im/old');
      expect(await im.videoCoverUrl(m), 'https://im/cover-old');
      await store.upsertMessage(
        m.copyWith(
          urlFetchedAt: DateTime.now().toUtc().subtract(
            const Duration(hours: 21),
          ),
        ),
      );
      expect(await im.videoUrl(m), 'https://im/new');
      expect((await im.conversationWith('u2'))!.lastMessage!.preview, '[视频]');
    });

    test('没有封面：不带封面的键，也不去重拉', () async {
      final m = await video();
      expect((sent.single['content'] as Map).keys, [
        'attachment_id',
        'ticket',
        'duration',
        'width',
        'height',
      ]);
      expect(await im.videoCoverUrl(m), null);
    });

    test('封面传过了、视频没传完：重发只传视频，进程重启后也带得上', () async {
      onUpload = (kind) =>
          kind == 'video' ? throw http.ClientException('断网') : null;
      final f = await video(cover: _png);
      expect((f.status, f.errorCode), (ImMessageStatus.failed, 'NETWORK'));
      await relogin();
      onUpload = null;
      expect((await im.resend(f)).status, ImMessageStatus.sent);
      expect(uploads.map((u) => u.kind), ['image', 'video', 'video']);
      expect((sent.single['content'] as Map)['cover_attachment_id'], 66);
    });

    test('封面断网：整条失败，重发再传封面；进程重启后不带封面', () async {
      onUpload = (_) => throw http.ClientException('断网');
      final a = await video(cover: _png);
      final b = await video(cover: _png);
      expect((a.status, a.errorCode), (ImMessageStatus.failed, 'NETWORK'));
      onUpload = null;
      expect((await im.resend(a)).status, ImMessageStatus.sent);
      expect((sent.last['content'] as Map)['cover_attachment_id'], 66);
      await relogin();
      expect((await im.resend(b)).status, ImMessageStatus.sent);
      expect(sent.last['content'], isNot(contains('cover_attachment_id')));
    });

    test('服务端不收封面：不带封面继续发', () async {
      onUpload = (kind) => kind == 'image' ? _error('VALIDATION', 400) : null;
      expect((await video(cover: _png)).status, ImMessageStatus.sent);
      expect(sent.single['content'], isNot(contains('cover_attachment_id')));
    });

    test('时长、宽高越界抛 ArgumentError', () {
      Future<ImMessage> send(Duration d, int w) => im.sendVideoBytes(
        'u2',
        Uint8List(1),
        duration: d,
        width: w,
        height: 10,
      );
      expect(() => send(Duration.zero, 10), throwsArgumentError);
      expect(
        () => send(const Duration(seconds: 3601), 10),
        throwsArgumentError,
      );
      expect(() => send(const Duration(seconds: 1), 0), throwsArgumentError);
    });
  });
}
