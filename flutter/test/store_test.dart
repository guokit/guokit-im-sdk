import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guokit_im/guokit_im.dart';
import 'package:guokit_im/src/store_sqlite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _t0 = DateTime.utc(2026, 11, 20, 2);

ImConversation _conv(int id, String peer, {int maxSeq = 0, int readSeq = 0}) =>
    ImConversation(
      id: id,
      type: 'c2c',
      peer: ImPeer(userId: peer, nickname: peer, avatarUrl: ''),
      maxSeq: maxSeq,
      readSeq: readSeq,
      lastMsgAt: _t0.add(Duration(minutes: id)),
    );

ImMessage _msg({
  int? id,
  int? seq,
  String from = 'u2',
  String cid = 'c',
  int? conv = 1,
}) => ImMessage(
  id: id,
  clientMsgId: cid,
  conversationId: conv,
  seq: seq,
  from: from,
  to: from == 'u1' ? 'u2' : 'u1',
  isSelf: from == 'u1',
  type: 'text',
  content: {'text': 'hi $cid'},
  status: id == null ? ImMessageStatus.sending : ImMessageStatus.sent,
  createdAt: _t0,
);

void main() {
  sqfliteFfiInit();
  final stores = <String, ImStore Function()>{
    '内存': MemoryImStore.new,
    'sqlite': () {
      final dir = Directory.systemTemp.createTempSync('guokit_im_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      return SqliteImStore(
        factory: databaseFactoryFfi,
        directory: () async => dir.path,
      );
    },
  };

  stores.forEach((name, create) {
    group(name, () {
      late ImStore s;
      setUp(() async {
        s = create();
        await s.open('u1');
        await s.upsertConversations([_conv(1, 'u2', maxSeq: 5, readSeq: 2)]);
      });
      tearDown(() => s.close());

      test('发送中按 clientMsgId 插入，服务端版本合并后只有一条、为 sent、保留 localPath', () async {
        final local = _msg(from: 'u1', cid: 'a', conv: null).copyWith(
          localPath: '/tmp/a.png',
          status: ImMessageStatus.failed,
          errorCode: 'NETWORK',
        );
        expect((await s.upsertMessage(local)).inserted, true);
        expect((await s.unconfirmedMessages('u2')).length, 1);

        final r = await s.upsertMessage(
          _msg(id: 9, seq: 6, from: 'u1', cid: 'a'),
        );
        expect(r.inserted, false);
        expect(
          (r.message.status, r.message.localPath, r.message.errorCode),
          (ImMessageStatus.sent, '/tmp/a.png', null),
        );
        expect(await s.unconfirmedMessages('u2'), isEmpty);
        expect((await s.messages(1)).single.id, 9);

        // 推送再到一次不新增；本地版本不能把已确认的降级
        expect(
          (await s.upsertMessage(
            _msg(id: 9, seq: 6, from: 'u1', cid: 'a'),
          )).inserted,
          false,
        );
        await s.upsertMessage(local);
        expect((await s.getMessageById(9))!.status, ImMessageStatus.sent);
        // 本人发的消息推进 maxSeq 并把 readSeq 推到该条
        final c = (await s.getConversation(1))!;
        expect((c.maxSeq, c.readSeq, c.lastMessage!.preview), (6, 6, 'hi a'));
      });

      test('按 id 去重', () async {
        await s.upsertMessage(_msg(id: 1, seq: 1, cid: 'x'));
        await s.upsertMessages([
          _msg(id: 1, seq: 1, cid: 'x'),
          _msg(id: 2, seq: 2, cid: 'y'),
        ]);
        expect((await s.messages(1)).map((m) => m.id), [1, 2]);
      });

      test('setReadSeq 只进不退；markAllRead 后 totalUnread 为 0', () async {
        await s.upsertConversations([_conv(2, 'u3', maxSeq: 4, readSeq: 1)]);
        expect(await s.totalUnread(), 6);
        expect((await s.setReadSeq(1, 4))!.readSeq, 4);
        expect((await s.setReadSeq(1, 3))!.readSeq, 4);
        await s.markAllRead();
        expect(await s.totalUnread(), 0);
        expect((await s.listConversations()).map((c) => c.id), [2, 1]);
      });

      test('messages 分页按 seq 升序；syncedSeq 沿连续段推进', () async {
        await s.upsertMessages([
          for (var i = 1; i <= 5; i++) _msg(id: i, seq: i, cid: 'm$i'),
        ]);
        expect((await s.messages(1, limit: 2)).map((m) => m.seq), [4, 5]);
        expect(
          (await s.messages(1, beforeSeq: 4, limit: 2)).map((m) => m.seq),
          [2, 3],
        );
        expect(await s.isContiguous(1, 1, 5), true);
        expect(await s.setSyncedSeq(1, 3), 5);
        await s.upsertMessage(_msg(id: 7, seq: 7, cid: 'm7'));
        expect(
          (await s.syncedSeq(1), await s.isContiguous(1, 5, 7)),
          (5, false),
        );
        await s.upsertMessage(_msg(id: 6, seq: 6, cid: 'm6'));
        expect(await s.syncedSeq(1), 7);
      });
    });
  });
}
