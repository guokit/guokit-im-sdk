/// 一次登录看到的存储：登出后任何读写都抛 [StateError]，换号后旧账号的迟到结果写不进新账号的库。
///
/// 只包一层，不改 [ImStore] 接口：底层存储跨登录共用，各实现都在调用那一刻就取定当前用户的库，
/// 所以调用前核一次就够。
library;

import 'models.dart';
import 'store.dart';

class SessionStore implements ImStore {
  SessionStore(this._inner);

  final ImStore _inner;
  bool _closed = false;

  /// 登出时调，只作废这一层，底层由门面关。
  void invalidate() => _closed = true;

  ImStore get _s => _closed ? throw StateError('已登出') : _inner;

  @override
  String? get userId => _s.userId;

  // 打开、关闭、删库归门面管。
  @override
  Future<void> open(String userId) => throw UnsupportedError('SessionStore');
  @override
  Future<void> close() => throw UnsupportedError('SessionStore');
  @override
  Future<void> deleteAll(String userId) =>
      throw UnsupportedError('SessionStore');

  @override
  Future<void> upsertConversations(List<ImConversation> list) async =>
      _s.upsertConversations(list);
  @override
  Future<ImConversation?> getConversation(int conversationId) async =>
      _s.getConversation(conversationId);
  @override
  Future<ImConversation?> conversationByPeer(String peerId) async =>
      _s.conversationByPeer(peerId);
  @override
  Future<List<ImConversation>> listConversations() async =>
      _s.listConversations();
  @override
  Future<ImConversation?> setReadSeq(int conversationId, int readSeq) async =>
      _s.setReadSeq(conversationId, readSeq);
  @override
  Future<void> markAllRead() async => _s.markAllRead();
  @override
  Future<int> totalUnread() async => _s.totalUnread();
  @override
  Future<void> clearMessages(int conversationId, int clearSeq) async =>
      _s.clearMessages(conversationId, clearSeq);
  @override
  Future<void> deleteConversation(int conversationId) async =>
      _s.deleteConversation(conversationId);
  @override
  Future<String?> changesCursor() async => _s.changesCursor();
  @override
  Future<void> setChangesCursor(String cursor) async =>
      _s.setChangesCursor(cursor);
  @override
  Future<String?> recallsCursor() async => _s.recallsCursor();
  @override
  Future<void> setRecallsCursor(String cursor) async =>
      _s.setRecallsCursor(cursor);
  @override
  Future<ImConversation?> setPeerReadSeq(
    int conversationId,
    int peerReadSeq,
  ) async => _s.setPeerReadSeq(conversationId, peerReadSeq);
  @override
  Future<int> syncedSeq(int conversationId) async =>
      _s.syncedSeq(conversationId);
  @override
  Future<int> setSyncedSeq(int conversationId, int seq) async =>
      _s.setSyncedSeq(conversationId, seq);

  @override
  Future<ImUpsertResult> upsertMessage(ImMessage message) async =>
      _s.upsertMessage(message);
  @override
  Future<List<ImUpsertResult>> upsertMessages(List<ImMessage> messages) async =>
      _s.upsertMessages(messages);
  @override
  Future<ImMessage?> getMessageById(int id) async => _s.getMessageById(id);
  @override
  Future<ImMessage?> getMessageByClientMsgId(
    String from,
    String clientMsgId,
  ) async => _s.getMessageByClientMsgId(from, clientMsgId);
  @override
  Future<List<ImMessage>> messages(
    int conversationId, {
    int? beforeSeq,
    int limit = 30,
  }) async => _s.messages(conversationId, beforeSeq: beforeSeq, limit: limit);
  @override
  Future<int> maxLocalSeq(int conversationId) async =>
      _s.maxLocalSeq(conversationId);
  @override
  Future<bool> isContiguous(int conversationId, int fromSeq, int toSeq) async =>
      _s.isContiguous(conversationId, fromSeq, toSeq);
  @override
  Future<List<ImMessage>> unconfirmedMessages(String peerId) async =>
      _s.unconfirmedMessages(peerId);
}
