import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guokit_im/guokit_im.dart';
import 'package:guokit_im/src/store.dart' show bumpConversation;
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

      test('置顶在前；免打扰不计总未读；changes 游标持久化', () async {
        ImConversation conv(int id, {int? pinned, bool muted = false}) =>
            _conv(id, 'p$id', maxSeq: 1).copyWith(
              pinnedAt: pinned == null
                  ? null
                  : _t0.add(Duration(hours: pinned)),
              muted: muted,
            );
        await s.upsertConversations([
          conv(2, pinned: 1),
          conv(3, pinned: 2),
          conv(4, muted: true),
        ]);
        expect((await s.listConversations()).map((c) => c.id), [3, 2, 4, 1]);
        expect(await s.totalUnread(), 5); // 会话 1 的 3 条 + 2、3 各 1 条
        expect(await s.changesCursor(), isNull);
        await s.setChangesCursor('a');
        await s.setChangesCursor('b');
        expect(await s.changesCursor(), 'b');
      });

      test('clearMessages 清掉旧消息、推进 syncedSeq，之后不再收清空范围内的', () async {
        await s.upsertMessages([
          for (var i = 1; i <= 5; i++) _msg(id: i, seq: i, cid: 'm$i'),
        ]);
        await s.setSyncedSeq(1, 2);
        await s.clearMessages(1, 4);
        expect((await s.messages(1)).map((m) => m.seq), [5]);
        final r = await s.upsertMessage(_msg(id: 3, seq: 3, cid: 'm3'));
        expect((r.inserted, await s.getMessageById(3)), (false, null));
        final c = (await s.getConversation(1))!;
        expect((c.clearSeq, c.readSeq, await s.syncedSeq(1)), (4, 4, 5));
        // 服务端 clear_seq 更大且最后消息为 null：不退回本地旧预览
        await s.upsertMessage(_msg(id: 6, seq: 6, cid: 'm6'));
        await s.upsertConversations([
          _conv(1, 'u2', maxSeq: 6, readSeq: 6).copyWith(clearSeq: 6),
        ]);
        expect((await s.getConversation(1))!.lastMessage, isNull);
      });

      test('deleteConversation 连消息一起删（含未确认的），不碰别的会话', () async {
        await s.upsertMessages([
          _msg(id: 1, seq: 1, cid: 'a'),
          _msg(from: 'u1', cid: 'b', conv: null),
          _msg(id: 9, seq: 1, cid: 'c', from: 'u3', conv: 2),
        ]);
        await s.deleteConversation(1);
        expect(await s.getConversation(1), isNull);
        expect(await s.messages(1), isEmpty);
        expect(await s.unconfirmedMessages('u2'), isEmpty);
        expect((await s.messages(2)).single.id, 9);
      });

      test('撤回不可逆：内容与预览替换、localPath 清空，旧版本与旧列表不覆盖', () async {
        final orig = _msg(id: 5, seq: 5, from: 'u1', cid: 'r');
        await s.upsertMessage(orig.copyWith(localPath: '/a.jpg'));
        await s.upsertConversations([
          (await s.getConversation(1))!.copyWith(
            lastMessage: ImMessagePreview(
              seq: 5,
              from: 'u1',
              type: 'text',
              preview: 'hi r',
              createdAt: _t0,
            ),
          ),
        ]);
        final stale = (await s.getConversation(1))!; // 在途的旧列表
        await s.upsertMessage(
          orig.copyWith(type: 'recalled', content: {'by': 'sender'}),
        );
        await s.upsertMessage(orig);
        await s.upsertConversations([stale]);
        final m = (await s.getMessageById(5))!;
        expect(
          (m.isRecalled, m.recalledBy, m.content['text'], m.localPath),
          (true, 'sender', null, null),
        );
        final c = (await s.getConversation(1))!;
        expect(
          (c.lastMessage!.preview, c.maxSeq, c.readSeq),
          ('[消息已撤回]', 5, 5),
        );
      });

      test('对方已读只进不退；服务端不给时置 null', () async {
        expect((await s.getConversation(1))!.peerReadSeq, null);
        await s.setPeerReadSeq(1, 4);
        await s.setPeerReadSeq(1, 2);
        expect((await s.getConversation(1))!.peerReadSeq, 4);
        await s.upsertConversations([
          _conv(1, 'u2', maxSeq: 5).copyWith(peerReadSeq: 3),
        ]);
        expect((await s.getConversation(1))!.peerReadSeq, 4);
        await s.upsertConversations([_conv(1, 'u2', maxSeq: 5)]);
        expect((await s.getConversation(1))!.peerReadSeq, null);
      });
    });
  });

  test('客服主体的第一条消息：会话类型是 service，取得到主体标识', () {
    final c = bumpConversation(
      null,
      _msg(id: 1, seq: 1, from: '@cs:shop_1', cid: 'b'),
    )!;
    expect((c.type, c.serviceId), ('service', 'shop_1'));
    expect(_conv(1, 'u2', maxSeq: 1).serviceId, null);
  });

  test('客服消息的 senderRole 入库读回，重复写入不丢', () async {
    for (final make in stores.values) {
      final s = make();
      await s.open('u1');
      addTearDown(s.close);
      final m = _msg(
        id: 1,
        seq: 1,
        from: '@cs',
        cid: 'b',
      ).copyWith(senderRole: 'bot');
      await s.upsertMessage(m);
      await s.upsertMessage(m.copyWith(senderRole: null));
      final got = (await s.getMessageById(1))!;
      expect((got.senderRole, got.isBot), ('bot', true));
      expect(ImMessage.fromJson(got.toJson()).isBot, true);
    }
  });

  test('sqlite 从 v1 升到最新：旧会话与消息保留，新列取默认值', () async {
    final dir = Directory.systemTemp.createTempSync('guokit_im_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = await databaseFactoryFfi.openDatabase(
      '${dir.path}/${sqliteFileName('u1')}',
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE conversations (id INTEGER PRIMARY KEY, type TEXT NOT NULL, peer_id TEXT NOT NULL, '
            "peer_nickname TEXT NOT NULL DEFAULT '', peer_avatar TEXT NOT NULL DEFAULT '', last_message TEXT, "
            'max_seq INTEGER NOT NULL DEFAULT 0, read_seq INTEGER NOT NULL DEFAULT 0, '
            'last_msg_at INTEGER NOT NULL, synced_seq INTEGER NOT NULL DEFAULT 0)',
          );
          await db.execute(
            'CREATE TABLE messages (local_id INTEGER PRIMARY KEY AUTOINCREMENT, id INTEGER UNIQUE, '
            'client_msg_id TEXT NOT NULL, conversation_id INTEGER, seq INTEGER, from_id TEXT NOT NULL, '
            'to_id TEXT NOT NULL, type TEXT NOT NULL, content TEXT NOT NULL, status TEXT NOT NULL, '
            'error_code TEXT, error_message TEXT, created_at INTEGER NOT NULL, local_path TEXT, '
            'url_fetched_at INTEGER, UNIQUE (from_id, client_msg_id))',
          );
        },
      ),
    );
    await db.insert('conversations', {
      'id': 1,
      'type': 'c2c',
      'peer_id': 'u2',
      'max_seq': 5,
      'last_msg_at': 0,
      'synced_seq': 3,
    });
    await db.insert('messages', {
      'id': 9,
      'client_msg_id': 'old',
      'conversation_id': 1,
      'seq': 5,
      'from_id': 'u2',
      'to_id': 'u1',
      'type': 'text',
      'content': '{"text":"hi"}',
      'status': 'sent',
      'created_at': 0,
    });
    await db.close();

    final s = SqliteImStore(
      factory: databaseFactoryFfi,
      directory: () async => dir.path,
    );
    await s.open('u1');
    addTearDown(s.close);
    final c = (await s.listConversations()).single;
    expect((c.maxSeq, c.pinnedAt, c.muted, c.clearSeq), (5, null, false, 0));
    expect(await s.syncedSeq(1), 3);
    expect((await s.messages(1)).single.senderRole, null);
    await s.setChangesCursor('a');
    await s.setRecallsCursor('b');
    expect((await s.changesCursor(), await s.recallsCursor()), ('a', 'b'));
    expect(c.peerReadSeq, null);
    expect((await s.setPeerReadSeq(1, 2))!.peerReadSeq, 2);
    await s.clearMessages(1, 5);
    expect((await s.getConversation(1))!.clearSeq, 5);
  });
}
