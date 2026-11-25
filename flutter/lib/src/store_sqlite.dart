/// SQLite 存储（iOS / Android）：每个用户一个库文件 `guokit_im_<userId>.db`，表结构见 spec §3.4。
///
/// 时间列一律存 UTC 毫秒时间戳（INTEGER）；`content`、`last_message` 存 JSON 文本；
/// `messages` 不存 is_self，读出时按 `from_id == 当前用户` 算。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';
import 'store.dart';

const _schema = [
  '''
CREATE TABLE conversations (
  id INTEGER PRIMARY KEY,
  type TEXT NOT NULL,
  peer_id TEXT NOT NULL,
  peer_nickname TEXT NOT NULL DEFAULT '',
  peer_avatar TEXT NOT NULL DEFAULT '',
  last_message TEXT,
  max_seq INTEGER NOT NULL DEFAULT 0,
  read_seq INTEGER NOT NULL DEFAULT 0,
  last_msg_at INTEGER NOT NULL,
  synced_seq INTEGER NOT NULL DEFAULT 0,
  pinned_at INTEGER,
  muted INTEGER NOT NULL DEFAULT 0,
  clear_seq INTEGER NOT NULL DEFAULT 0,
  peer_read_seq INTEGER
)''',
  'CREATE INDEX idx_conversations_peer ON conversations (peer_id)',
  '''
CREATE TABLE messages (
  local_id INTEGER PRIMARY KEY AUTOINCREMENT,
  id INTEGER UNIQUE,
  client_msg_id TEXT NOT NULL,
  conversation_id INTEGER,
  seq INTEGER,
  from_id TEXT NOT NULL,
  to_id TEXT NOT NULL,
  type TEXT NOT NULL,
  content TEXT NOT NULL,
  status TEXT NOT NULL,
  error_code TEXT,
  error_message TEXT,
  created_at INTEGER NOT NULL,
  local_path TEXT,
  url_fetched_at INTEGER,
  sender_role TEXT,
  UNIQUE (from_id, client_msg_id)
)''',
  'CREATE INDEX idx_messages_conv_seq ON messages (conversation_id, seq)',
  _metaSchema,
];

/// 键值表，存会话设置与撤回增量补齐的游标。
const _metaSchema =
    'CREATE TABLE meta (name TEXT PRIMARY KEY, value TEXT NOT NULL)';
const _changesCursorName = 'conversation_changes_cursor';
const _recallsCursorName = 'recalls_cursor';

/// v1 → v2（会话置顶、免打扰、清空）。
const _upgradeV2 = [
  'ALTER TABLE conversations ADD COLUMN pinned_at INTEGER',
  'ALTER TABLE conversations ADD COLUMN muted INTEGER NOT NULL DEFAULT 0',
  'ALTER TABLE conversations ADD COLUMN clear_seq INTEGER NOT NULL DEFAULT 0',
  _metaSchema,
];

/// v2 → v3（客服消息的发送者角色）。
const _upgradeV3 = ['ALTER TABLE messages ADD COLUMN sender_role TEXT'];

/// v3 → v4（对方已读）。可空：null = 站点没开启 / 旧服务端 / 客服会话。
const _upgradeV4 = [
  'ALTER TABLE conversations ADD COLUMN peer_read_seq INTEGER',
];

/// 库文件名：userId 里 `[A-Za-z0-9_-]` 以外的字符换成 `_`。
String sqliteFileName(String userId) =>
    'guokit_im_${userId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.db';

class SqliteImStore implements ImStore {
  /// [factory] 默认 sqflite 的全局 `databaseFactory`（测试传 `databaseFactoryFfi`）；
  /// [directory] 默认 `getApplicationSupportDirectory()`。
  SqliteImStore({
    DatabaseFactory? factory,
    Future<String> Function()? directory,
  }) : _factory = factory ?? databaseFactory,
       _directory = directory ?? _defaultDirectory;

  static Future<String> _defaultDirectory() async =>
      (await getApplicationSupportDirectory()).path;

  final DatabaseFactory _factory;
  final Future<String> Function() _directory;

  Database? _db;
  String? _userId;

  @override
  String? get userId => _userId;

  Database get _conn {
    final db = _db;
    if (db == null) throw StateError('ImStore 未打开');
    return db;
  }

  Future<String> _pathOf(String userId) async =>
      p.join(await _directory(), sqliteFileName(userId));

  @override
  Future<void> open(String userId) async {
    if (_db != null && _userId == userId) return;
    await close();
    final path = await _pathOf(userId);
    await Directory(p.dirname(path)).create(recursive: true);
    _db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, _) async {
          for (final sql in _schema) {
            await db.execute(sql);
          }
        },
        onUpgrade: (db, from, _) async {
          if (from < 2) {
            for (final sql in _upgradeV2) {
              await db.execute(sql);
            }
          }
          if (from < 3) {
            for (final sql in _upgradeV3) {
              await db.execute(sql);
            }
          }
          if (from < 4) {
            for (final sql in _upgradeV4) {
              await db.execute(sql);
            }
          }
        },
      ),
    );
    _userId = userId;
  }

  @override
  Future<void> close() async {
    final db = _db;
    _db = null;
    _userId = null;
    await db?.close();
  }

  @override
  Future<void> deleteAll(String userId) async {
    if (_userId == userId) await close();
    await _factory.deleteDatabase(await _pathOf(userId));
  }

  // ---------------- 行映射 ----------------

  static Map<String, Object?> _convRow(ImConversation c) => {
    'id': c.id,
    'type': c.type,
    'peer_id': c.peer.userId,
    'peer_nickname': c.peer.nickname,
    'peer_avatar': c.peer.avatarUrl,
    'last_message': c.lastMessage == null
        ? null
        : jsonEncode(c.lastMessage!.toJson()),
    'max_seq': c.maxSeq,
    'read_seq': c.readSeq,
    'last_msg_at': c.lastMsgAt.millisecondsSinceEpoch,
    'pinned_at': c.pinnedAt?.millisecondsSinceEpoch,
    'muted': c.muted ? 1 : 0,
    'clear_seq': c.clearSeq,
    'peer_read_seq': c.peerReadSeq,
  };

  static ImConversation _conv(Map<String, Object?> r) {
    final last = r['last_message'] as String?;
    final pinned = r['pinned_at'] as int?;
    return ImConversation(
      id: r['id'] as int,
      type: r['type'] as String,
      peer: ImPeer(
        userId: r['peer_id'] as String,
        nickname: r['peer_nickname'] as String,
        avatarUrl: r['peer_avatar'] as String,
      ),
      lastMessage: last == null
          ? null
          : ImMessagePreview.fromJson(jsonDecode(last) as Map),
      maxSeq: r['max_seq'] as int,
      readSeq: r['read_seq'] as int,
      lastMsgAt: DateTime.fromMillisecondsSinceEpoch(
        r['last_msg_at'] as int,
        isUtc: true,
      ),
      pinnedAt: pinned == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(pinned, isUtc: true),
      muted: r['muted'] == 1,
      clearSeq: r['clear_seq'] as int,
      peerReadSeq: r['peer_read_seq'] as int?,
    );
  }

  static Map<String, Object?> _msgRow(ImMessage m) => {
    'id': m.id,
    'client_msg_id': m.clientMsgId,
    'conversation_id': m.conversationId,
    'seq': m.seq,
    'from_id': m.from,
    'to_id': m.to,
    'type': m.type,
    'content': jsonEncode(m.content),
    'status': m.status.name,
    'error_code': m.errorCode,
    'error_message': m.errorMessage,
    'created_at': m.createdAt.millisecondsSinceEpoch,
    'local_path': m.localPath,
    'url_fetched_at': m.urlFetchedAt?.millisecondsSinceEpoch,
    'sender_role': m.senderRole,
  };

  ImMessage _msg(Map<String, Object?> r) {
    final fetched = r['url_fetched_at'] as int?;
    return ImMessage(
      id: r['id'] as int?,
      clientMsgId: r['client_msg_id'] as String,
      conversationId: r['conversation_id'] as int?,
      seq: r['seq'] as int?,
      from: r['from_id'] as String,
      to: r['to_id'] as String,
      isSelf: r['from_id'] == _userId,
      type: r['type'] as String,
      content: Map<String, dynamic>.from(
        jsonDecode(r['content'] as String) as Map,
      ),
      status: ImMessageStatus.values.byName(r['status'] as String),
      errorCode: r['error_code'] as String?,
      errorMessage: r['error_message'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        r['created_at'] as int,
        isUtc: true,
      ),
      localPath: r['local_path'] as String?,
      urlFetchedAt: fetched == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(fetched, isUtc: true),
      senderRole: r['sender_role'] as String?,
    );
  }

  static Future<ImConversation?> _getConv(DatabaseExecutor db, int id) async {
    final rows = await db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : _conv(rows.first);
  }

  /// 写会话元数据（不碰 synced_seq；新行 synced_seq 取默认 0）。
  static Future<void> _putConv(DatabaseExecutor db, ImConversation c) async {
    final row = _convRow(c);
    final n = await db.update(
      'conversations',
      row,
      where: 'id = ?',
      whereArgs: [c.id],
    );
    if (n == 0) await db.insert('conversations', row);
  }

  // ---------------- 会话 ----------------

  @override
  Future<void> upsertConversations(List<ImConversation> list) =>
      _conn.transaction((txn) async {
        for (final c in list) {
          await _putConv(txn, mergeConversation(await _getConv(txn, c.id), c));
        }
      });

  @override
  Future<ImConversation?> getConversation(int conversationId) =>
      _getConv(_conn, conversationId);

  @override
  Future<ImConversation?> conversationByPeer(String peerId) async {
    final rows = await _conn.query(
      'conversations',
      where: 'peer_id = ?',
      whereArgs: [peerId],
      limit: 1,
    );
    return rows.isEmpty ? null : _conv(rows.first);
  }

  @override
  Future<List<ImConversation>> listConversations() async {
    final rows = await _conn.query(
      'conversations',
      // SQLite 里 NULL 小于任何值，DESC 时未置顶的自然排最后。
      orderBy: 'pinned_at DESC, last_msg_at DESC, id DESC',
    );
    return rows.map(_conv).toList();
  }

  @override
  Future<ImConversation?> setReadSeq(int conversationId, int readSeq) async {
    final db = _conn;
    await db.update(
      'conversations',
      {'read_seq': readSeq},
      where: 'id = ? AND read_seq < ?',
      whereArgs: [conversationId, readSeq],
    );
    return _getConv(db, conversationId);
  }

  @override
  Future<void> markAllRead() => _conn.rawUpdate(
    'UPDATE conversations SET read_seq = max_seq WHERE read_seq < max_seq',
  );

  @override
  Future<int> totalUnread() async {
    final rows = await _conn.rawQuery(
      'SELECT COALESCE(SUM(max_seq - read_seq), 0) AS n FROM conversations WHERE max_seq > read_seq AND muted = 0',
    );
    return rows.first['n'] as int;
  }

  @override
  Future<void> clearMessages(int conversationId, int clearSeq) =>
      _conn.transaction((txn) async {
        final c = await _getConv(txn, conversationId);
        if (c == null || clearSeq <= c.clearSeq) return;
        await _putConv(txn, clearedConversation(c, clearSeq));
        await txn.delete(
          'messages',
          where: 'conversation_id = ? AND seq <= ?',
          whereArgs: [conversationId, clearSeq],
        );
        final synced = await _getSynced(txn, conversationId);
        await _setSynced(txn, conversationId, math.max(synced, clearSeq));
      });

  @override
  Future<void> deleteConversation(int conversationId) => _conn.transaction((
    txn,
  ) async {
    final c = await _getConv(txn, conversationId);
    await txn.delete(
      'messages',
      where:
          'conversation_id = ? OR (seq IS NULL AND from_id = ? AND to_id = ?)',
      whereArgs: [conversationId, _userId, c?.peer.userId ?? ''],
    );
    await txn.delete(
      'conversations',
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  });

  Future<String?> _meta(String name) async {
    final rows = await _conn.query(
      'meta',
      where: 'name = ?',
      whereArgs: [name],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> _setMeta(String name, String value) => _conn.insert('meta', {
    'name': name,
    'value': value,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<String?> changesCursor() => _meta(_changesCursorName);

  @override
  Future<void> setChangesCursor(String cursor) =>
      _setMeta(_changesCursorName, cursor);

  @override
  Future<String?> recallsCursor() => _meta(_recallsCursorName);

  @override
  Future<void> setRecallsCursor(String cursor) =>
      _setMeta(_recallsCursorName, cursor);

  @override
  Future<ImConversation?> setPeerReadSeq(int conversationId, int peerReadSeq) =>
      _conn.transaction((txn) async {
        await txn.rawUpdate(
          'UPDATE conversations SET peer_read_seq = ? WHERE id = ? '
          'AND (peer_read_seq IS NULL OR peer_read_seq < ?)',
          [peerReadSeq, conversationId, peerReadSeq],
        );
        return _getConv(txn, conversationId);
      });

  @override
  Future<int> syncedSeq(int conversationId) =>
      _getSynced(_conn, conversationId);

  static Future<int> _getSynced(DatabaseExecutor db, int conversationId) async {
    final rows = await db.query(
      'conversations',
      columns: ['synced_seq'],
      where: 'id = ?',
      whereArgs: [conversationId],
    );
    return rows.isEmpty ? 0 : rows.first['synced_seq'] as int;
  }

  @override
  Future<int> setSyncedSeq(int conversationId, int seq) =>
      _setSynced(_conn, conversationId, seq);

  static Future<int> _setSynced(
    DatabaseExecutor db,
    int conversationId,
    int seq,
  ) async {
    final rows = await db.rawQuery(
      'SELECT seq FROM messages WHERE conversation_id = ? AND seq > ? ORDER BY seq',
      [conversationId, seq],
    );
    final s = advanceSynced(seq, rows.map((r) => r['seq'] as int));
    final n = await db.update(
      'conversations',
      {'synced_seq': s},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
    return n == 0 ? 0 : s;
  }

  // ---------------- 消息 ----------------

  Future<ImUpsertResult> _upsert(DatabaseExecutor db, ImMessage message) async {
    var rows = message.id == null
        ? const <Map<String, Object?>>[]
        : await db.query('messages', where: 'id = ?', whereArgs: [message.id]);
    if (rows.isEmpty) {
      rows = await db.query(
        'messages',
        where: 'from_id = ? AND client_msg_id = ?',
        whereArgs: [message.from, message.clientMsgId],
      );
    }
    final inserted = rows.isEmpty;
    final merged = inserted ? message : mergeMessage(_msg(rows.first), message);
    final conv = isConfirmed(merged)
        ? await _getConv(db, merged.conversationId!)
        : null;
    if (conv != null && merged.seq! <= conv.clearSeq) {
      if (!inserted) {
        await db.delete(
          'messages',
          where: 'local_id = ?',
          whereArgs: [rows.first['local_id']],
        );
      }
      return (message: merged, inserted: false);
    }
    if (inserted) {
      await db.insert('messages', _msgRow(merged));
    } else {
      await db.update(
        'messages',
        _msgRow(merged),
        where: 'local_id = ?',
        whereArgs: [rows.first['local_id']],
      );
    }

    if (isConfirmed(merged)) {
      final convId = merged.conversationId!;
      final bumped = bumpConversation(conv, merged);
      if (bumped != null && !identical(bumped, conv)) {
        await _putConv(db, bumped);
      }
      final s = await _getSynced(db, convId);
      if (s > 0 && merged.seq == s + 1) await _setSynced(db, convId, s);
    }
    return (message: merged, inserted: inserted);
  }

  @override
  Future<ImUpsertResult> upsertMessage(ImMessage message) =>
      _conn.transaction((txn) => _upsert(txn, message));

  @override
  Future<List<ImUpsertResult>> upsertMessages(List<ImMessage> messages) =>
      _conn.transaction(
        (txn) async => [for (final m in messages) await _upsert(txn, m)],
      );

  @override
  Future<ImMessage?> getMessageById(int id) async {
    final rows = await _conn.query(
      'messages',
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : _msg(rows.first);
  }

  @override
  Future<ImMessage?> getMessageByClientMsgId(
    String from,
    String clientMsgId,
  ) async {
    final rows = await _conn.query(
      'messages',
      where: 'from_id = ? AND client_msg_id = ?',
      whereArgs: [from, clientMsgId],
    );
    return rows.isEmpty ? null : _msg(rows.first);
  }

  @override
  Future<List<ImMessage>> messages(
    int conversationId, {
    int? beforeSeq,
    int limit = 30,
  }) async {
    final rows = await _conn.query(
      'messages',
      where: beforeSeq == null
          ? 'conversation_id = ? AND seq IS NOT NULL'
          : 'conversation_id = ? AND seq IS NOT NULL AND seq < ?',
      whereArgs: [conversationId, if (beforeSeq != null) beforeSeq],
      orderBy: 'seq DESC',
      limit: limit,
    );
    return rows.reversed.map(_msg).toList();
  }

  @override
  Future<int> maxLocalSeq(int conversationId) async {
    final rows = await _conn.rawQuery(
      'SELECT COALESCE(MAX(seq), 0) AS n FROM messages WHERE conversation_id = ?',
      [conversationId],
    );
    return rows.first['n'] as int;
  }

  @override
  Future<bool> isContiguous(int conversationId, int fromSeq, int toSeq) async {
    if (fromSeq > toSeq) return true;
    final rows = await _conn.rawQuery(
      'SELECT COUNT(DISTINCT seq) AS n FROM messages '
      'WHERE conversation_id = ? AND seq BETWEEN ? AND ?',
      [conversationId, fromSeq, toSeq],
    );
    return rows.first['n'] == toSeq - fromSeq + 1;
  }

  @override
  Future<List<ImMessage>> unconfirmedMessages(String peerId) async {
    final rows = await _conn.query(
      'messages',
      where: 'seq IS NULL AND from_id = ? AND to_id = ?',
      whereArgs: [_userId, peerId],
      orderBy: 'local_id',
    );
    return rows.map(_msg).toList();
  }
}
