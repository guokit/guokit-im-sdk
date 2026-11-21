import 'package:flutter_test/flutter_test.dart';
import 'package:guokit_im/guokit_im.dart';
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
}
