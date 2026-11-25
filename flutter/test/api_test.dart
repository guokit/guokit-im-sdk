import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guokit_im/guokit_im.dart';
import 'package:guokit_im/src/api.dart';
import 'package:guokit_im/src/token.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _res(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

final _week = DateTime.now().toUtc().add(const Duration(days: 7));

void main() {
  test('两个请求同时 401 只调一次 provider，且都在重试后成功', () async {
    var calls = 0;
    // 第一次给出 old（服务端已判失效），之后给 fresh。
    final tokens = TokenManager(() async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return ImToken(calls == 1 ? 'old' : 'fresh', _week);
    });
    await tokens.current();

    final api = ImApi(
      baseUrl: 'https://im.example.com/',
      tokens: tokens,
      client: MockClient((req) async {
        expect(req.url.toString(), 'https://im.example.com/api/im/v1/unread');
        if (req.headers['Authorization'] == 'Bearer fresh') {
          return _res({
            'code': 0,
            'message': 'ok',
            'data': {'total': 5},
          });
        }
        return _res({
          'code': 'IM_TOKEN_INVALID',
          'message': '令牌无效',
          'data': {},
        }, 401);
      }),
    );

    expect(await Future.wait([api.unread(), api.unread()]), [5, 5]);
    expect(calls, 2); // 1 次初取 + 并发 401 共享的 1 次换新
  });

  test('业务失败抛带 code 的 ImApiException', () async {
    final api = ImApi(
      baseUrl: 'https://im.example.com',
      tokens: TokenManager(() async => ImToken('t', _week)),
      client: MockClient((req) async {
        expect(jsonDecode(req.body), containsPair('client_msg_id', 'c1'));
        return _res({'code': 'IM_BLOCKED', 'message': '对方已将你拉黑', 'data': {}});
      }),
    );

    await expectLater(
      api.sendMessage(
        to: 'u2',
        type: 'text',
        content: {'text': 'hi'},
        clientMsgId: 'c1',
      ),
      throwsA(
        isA<ImApiException>()
            .having((e) => e.code, 'code', 'IM_BLOCKED')
            .having((e) => e.httpStatus, 'httpStatus', 200)
            .having((e) => e.isTemporary, 'isTemporary', false),
      ),
    );
  });

  test('客服主体：客服号换算；接待状态带 service_id，默认不带', () async {
    expect(csUserId(), '@cs');
    expect(csUserId('shop_1'), '@cs:shop_1');
    expect(csServiceId('@cs'), '');
    expect(csServiceId('@cs:shop_1'), 'shop_1');
    expect(csServiceId('u1'), isNull);
    final seen = <String>[];
    final api = ImApi(
      baseUrl: 'https://im.example.com',
      tokens: TokenManager(() async => ImToken('t', _week)),
      client: MockClient((req) async {
        seen.add(req.url.toString());
        return _res({
          'code': 0,
          'message': 'ok',
          'data': {'status': 'active', 'session_id': 1, 'queue_position': 0},
        });
      }),
    );
    await api.csState();
    await api.csState(serviceId: 'shop_1');
    expect(seen, [
      'https://im.example.com/api/imcs/v1/state',
      'https://im.example.com/api/imcs/v1/state?service_id=shop_1',
    ]);
  });

  test('转人工走 /api/imcs/v1/handoff；不认识的状态按 none', () async {
    var status = 'bot';
    final seen = <String>[];
    final api = ImApi(
      baseUrl: 'https://im.example.com',
      tokens: TokenManager(() async => ImToken('t', _week)),
      client: MockClient((req) async {
        seen.add('${req.method} ${req.url.path}');
        if (req.method == 'POST') status = 'queued';
        return _res({
          'code': 0,
          'message': 'ok',
          'data': {'status': status, 'session_id': 1, 'queue_position': 0},
        });
      }),
    );
    expect((await api.csState()).status, ImCsStatus.bot);
    expect((await api.csHandoff()).status, ImCsStatus.queued);
    status = 'someday';
    expect((await api.csState()).status, ImCsStatus.none);
    expect(seen[1], 'POST /api/imcs/v1/handoff');
  });

  test('没有坐席在时留联系方式：状态字段、请求体、单号与错误', () async {
    var data = <String, Object?>{
      'status': 'queued',
      'session_id': 1,
      'queue_position': 1,
    };
    final bodies = <String>[];
    var mode = 'ok';
    final api = ImApi(
      baseUrl: 'https://im.example.com',
      tokens: TokenManager(() async => ImToken('t', _week)),
      client: MockClient((req) async {
        if (req.method == 'GET') {
          return _res({'code': 0, 'message': 'ok', 'data': data});
        }
        expect(req.url.path, '/api/imcs/v1/leave');
        bodies.add(req.body);
        return switch (mode) {
          'ok' => _res({
            'code': 0,
            'message': 'ok',
            'data': {'ticket_no': 'T20261124123456'},
          }),
          'off' => _res({
            'code': 'VALIDATION',
            'message': '没有开启留言',
            'data': {},
          }, 404),
          _ => _res({'code': 'IM_RATE_LIMITED', 'message': '太频繁了', 'data': {}}),
        };
      }),
    );
    // 旧服务端不给这两个字段
    var st = await api.csState();
    expect(
      (st.agentsOnline, st.leaveEnabled, st.canLeave),
      (true, false, false),
    );
    data = {...data, 'agents_online': false, 'leave_enabled': true};
    st = await api.csState();
    expect(
      (st.agentsOnline, st.leaveEnabled, st.canLeave),
      (false, true, true),
    );
    data = {...data, 'status': 'none'};
    expect((await api.csState()).canLeave, false);

    expect(
      await api.csLeave(name: '张三', phone: '13800000000', email: ''),
      'T20261124123456',
    );
    expect(jsonDecode(bodies.single), {
      'contact_name': '张三',
      'contact_phone': '13800000000',
    });
    mode = 'off';
    await expectLater(
      api.csLeave(email: 'a@b.cn'),
      throwsA(
        isA<ImApiException>()
            .having((e) => e.code, 'code', 'VALIDATION')
            .having((e) => e.httpStatus, 'httpStatus', 404),
      ),
    );
    mode = 'limit';
    await expectLater(
      api.csLeave(email: 'a@b.cn'),
      throwsA(
        isA<ImApiException>().having((e) => e.code, 'code', 'IM_RATE_LIMITED'),
      ),
    );
  });

  test('客服接口走 /api/imcs/v1：取状态、评价，「无法评价」抛 VALIDATION', () async {
    final seen = <String>[];
    final api = ImApi(
      baseUrl: 'https://im.example.com',
      tokens: TokenManager(() async => ImToken('t', _week)),
      client: MockClient((req) async {
        seen.add('${req.method} ${req.url}');
        if (req.method == 'GET') {
          return _res({
            'code': 0,
            'message': 'ok',
            'data': {
              'status': 'queued',
              'session_id': 305,
              'queue_position': 2,
            },
          });
        }
        final body = jsonDecode(req.body) as Map;
        if (body['rating'] == 5) {
          expect(body, {'rating': 5, 'comment': '很及时'});
          return _res({
            'code': 0,
            'message': 'ok',
            'data': {'id': 305},
          });
        }
        return _res({'code': 'VALIDATION', 'message': '无法评价', 'data': {}}, 400);
      }),
    );

    final st = await api.csState();
    expect(
      (st.status, st.sessionId, st.queuePosition),
      (ImCsStatus.queued, 305, 2),
    );
    await api.csRate(305, 5, comment: '很及时');
    await expectLater(
      api.csRate(305, 4),
      throwsA(
        isA<ImApiException>().having((e) => e.code, 'code', 'VALIDATION'),
      ),
    );
    expect(seen, [
      'GET https://im.example.com/api/imcs/v1/state',
      'POST https://im.example.com/api/imcs/v1/sessions/305/rating',
      'POST https://im.example.com/api/imcs/v1/sessions/305/rating',
    ]);
  });
}
