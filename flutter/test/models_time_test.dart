import 'package:flutter_test/flutter_test.dart';
import 'package:guokit_im/guokit_im.dart';
import 'package:guokit_im/src/store.dart';
import 'package:guokit_im/src/time.dart';

void main() {
  test('东八区时间解析成 UTC，跨日借位正确', () {
    expect(parseCst('2026-11-20 10:00:00'), DateTime.utc(2026, 11, 20, 2));
    expect(parseCst('2026-11-20 03:00:00'), DateTime.utc(2026, 11, 19, 19));
    expect(formatCst(DateTime.utc(2026, 11, 19, 19)), '2026-11-20 03:00:00');
    expect(() => parseCst('2026-11-20T10:00:00Z'), throwsFormatException);
  });

  test('ImMessage.fromServer 推导 to 与 isSelf', () {
    Map<String, dynamic> msg(String from) => {
      'id': 1024,
      'conversation_id': 12,
      'seq': 37,
      'from': from,
      'type': 'text',
      'content': {'text': '你好'},
      'client_msg_id': 'c1',
      'created_at': '2026-11-20 10:00:00',
    };

    final inbound = ImMessage.fromServer(msg('u2'), me: 'u1', peerId: 'u2');
    expect(
      (inbound.to, inbound.isSelf, inbound.status),
      ('u1', false, ImMessageStatus.sent),
    );

    expect(inbound.senderRole, null);
    expect(
      ImMessage.fromServer({
        ...msg('@cs'),
        'sender_role': 'bot',
      }, me: 'u1').isBot,
      true,
    );

    final outbound = ImMessage.fromServer(msg('u1'), me: 'u1', peerId: 'u2');
    expect((outbound.to, outbound.isSelf), ('u2', true));
    expect(outbound.createdAt, DateTime.utc(2026, 11, 20, 2));

    // 存储格式往返
    final back = ImMessage.fromJson(outbound.toJson());
    expect(
      (back.to, back.seq, back.content['text'], back.createdAt),
      ('u2', 37, '你好', outbound.createdAt),
    );
  });

  test('文件预览合计 50 字，视频固定文字；站点开关缺省全关', () {
    ImMessage msg(String type, Map<String, dynamic> content) => ImMessage(
      clientMsgId: 'c1',
      from: 'u1',
      to: 'u2',
      isSelf: true,
      type: type,
      content: content,
      status: ImMessageStatus.sending,
      createdAt: DateTime.utc(2026),
    );
    final long = '长' * 60;
    expect(previewOf(msg('file', {'name': 'a.pdf'})), '[文件] a.pdf');
    expect(previewOf(msg('file', {'name': long})), '[文件] ${'长' * 45}');
    expect(previewOf(msg('video', {})), '[视频]');
    final text = msg('text', {'text': 'x', 'size': 1, 'name': 'n'});
    expect(
      (text.fileName, text.fileSize, text.videoDuration),
      (null, null, null),
    );

    // 旧版服务端没有 features，或没有这两项
    final old = ImFeatures.fromServer({
      'features': {'recall_minutes': 2, 'read_receipt': true},
    });
    expect((old.recallMinutes, old.fileMaxMb, old.videoMaxMb), (2, 0, 0));
    const built = ImFeatures(recallMinutes: 0, readReceipt: false);
    expect((built.fileMaxMb, built.videoMaxMb), (0, 0));
    final on = ImFeatures.fromServer({
      'features': {'file_max_mb': 20, 'video_max_mb': 45},
    });
    expect((on.fileMaxMb, on.videoMaxMb), (20, 45));
  });
}
