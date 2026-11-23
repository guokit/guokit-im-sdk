import 'package:flutter_test/flutter_test.dart';
import 'package:guokit_im/guokit_im.dart';

void main() {
  test('合法卡片逐字段解析，ImMessage.card 取到同一张', () {
    final data = {
      'order_id': 1,
      'im_card': {
        'kind': 'order',
        'title': '订单 #20261123001',
        'subtitle': '待发货',
        'fields': [
          {'label': '金额', 'value': '¥99.00'},
          {'label': '', 'value': '丢弃'},
          {'label': '数量', 'value': 2},
        ],
        'web_link': 'https://shop.example.com/order/1',
        'mp_path': '/pages/order/detail?id=1',
        'mp_appid': 'wx1234567890abcdef',
        'image': 123,
      },
    };
    final card = ImCard.tryParse(data)!;
    expect(card.kind, 'order');
    expect(card.title, '订单 #20261123001');
    expect(card.subtitle, '待发货');
    expect(card.image, isNull);
    expect(card.fields.map((f) => (f.label, f.value)).toList(), [
      ('金额', '¥99.00'),
    ]);
    expect(card.webLink, 'https://shop.example.com/order/1');
    expect(card.appLink, isNull);
    expect(card.mpPath, '/pages/order/detail?id=1');
    expect(card.mpAppid, 'wx1234567890abcdef');

    final msg = ImMessage.fromServer({
      'id': 1,
      'conversation_id': 2,
      'seq': 3,
      'from': 'u2',
      'type': 'custom',
      'content': {'data': data, 'desc': '[订单]'},
      'client_msg_id': 'c1',
      'created_at': '2026-11-23 10:00:00',
    }, me: 'u1');
    expect(msg.card?.title, '订单 #20261123001');
    expect(msg.card?.webLink, 'https://shop.example.com/order/1');
  });

  test('缺 title 返回 null', () {
    expect(
      ImCard.tryParse({
        'im_card': {'kind': 'order', 'web_link': 'https://a.example.com'},
      }),
      isNull,
    );
  });
}
