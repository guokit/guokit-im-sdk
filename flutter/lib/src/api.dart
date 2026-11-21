/// IM 客户端 HTTP 接口（接入文档 §5）。
///
/// 只做传输：拼前缀、带令牌、解析响应包、401 换令牌重试一次。
/// 返回值约定：
/// - 不依赖当前用户就能解析的，直接转模型：[ImApi.me] → [ImPeer]、
///   [ImApi.conversations] → [ImConversation]、[ImApi.blocks] → [ImBlockItem]；
/// - 消息相关（[ImApi.sendMessage]、[ImApi.messages]）返回服务端原始 Map，
///   因为推导 `to` 需要当前用户与会话对方，由上层调 `ImMessage.fromServer`。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'models.dart';
import 'token.dart';

typedef _Build = http.BaseRequest Function(String token);

class ImApi {
  ImApi({
    required String baseUrl,
    required TokenManager tokens,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _base = baseUrl.endsWith('/')
           ? baseUrl.substring(0, baseUrl.length - 1)
           : baseUrl,
       _tokens = tokens,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  static const String _prefix = '/api/im/v1';

  final String _base;
  final TokenManager _tokens;
  final http.Client _client;
  final bool _ownsClient;

  /// 单次请求（发出到读完响应体）的超时，超时抛 `ImApiException('NETWORK', …, 0)`。
  final Duration timeout;

  /// `GET /me`：当前用户，可用作令牌自检。
  Future<ImPeer> me() async =>
      ImPeer.fromServer(await _json('GET', '/me') as Map);

  /// `POST /messages`：发消息，返回服务端消息对象（原始 Map）。
  ///
  /// 业务失败（`IM_USER_NOT_FOUND` / `IM_BLOCKED` / `IM_RATE_LIMITED` 等）抛 [ImApiException]，
  /// 状态映射交给发送层（spec §3.5）。
  Future<Map<String, dynamic>> sendMessage({
    required String to,
    required String type,
    required Map<String, dynamic> content,
    required String clientMsgId,
  }) async => _asMap(
    await _json(
      'POST',
      '/messages',
      body: {
        'to': to,
        'type': type,
        'content': content,
        'client_msg_id': clientMsgId,
      },
    ),
  );

  /// `POST /upload`：上传图片（multipart 字段 `file`）。服务端按内容识别格式，[filename] 只作展示。
  Future<({int attachmentId, String url, String ticket})> upload(
    List<int> bytes,
    String filename,
  ) async {
    final d = _asMap(
      await _send((token) {
        final r = http.MultipartRequest('POST', _uri('/upload'))
          ..headers['Authorization'] = 'Bearer $token'
          ..files.add(
            http.MultipartFile.fromBytes('file', bytes, filename: filename),
          );
        return r;
      }),
    );
    return (
      attachmentId: (d['attachment_id'] as num).toInt(),
      url: d['url'] as String,
      ticket: d['ticket'] as String,
    );
  }

  /// `GET /conversations`：会话列表一页。[nextCursor] 为 null 表示没有下一页（服务端回的是空串）。
  Future<({List<ImConversation> items, String? nextCursor})> conversations({
    String? cursor,
    int? limit,
  }) async {
    final d = _asMap(
      await _json(
        'GET',
        '/conversations',
        query: {
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
          if (limit != null) 'limit': '$limit',
        },
      ),
    );
    final next = d['next_cursor'] as String?;
    return (
      items: [
        for (final e in d['items'] as List) ImConversation.fromServer(e as Map),
      ],
      nextCursor: (next == null || next.isEmpty) ? null : next,
    );
  }

  /// `GET /unread`：总未读。
  Future<int> unread() async =>
      (_asMap(await _json('GET', '/unread'))['total'] as num).toInt();

  /// `GET /conversations/{id}/messages`：[afterSeq] 补拉、[beforeSeq] 翻历史、都不传为最新一页，
  /// 只能传一个。`items` 为服务端原始消息 Map，按 seq 升序。
  Future<({List<Map<String, dynamic>> items, bool hasMore})> messages(
    int conversationId, {
    int? afterSeq,
    int? beforeSeq,
    int? limit,
  }) async {
    if (afterSeq != null && beforeSeq != null) {
      throw ArgumentError('afterSeq 与 beforeSeq 只能传一个');
    }
    final d = _asMap(
      await _json(
        'GET',
        '/conversations/$conversationId/messages',
        query: {
          if (afterSeq != null) 'after_seq': '$afterSeq',
          if (beforeSeq != null) 'before_seq': '$beforeSeq',
          if (limit != null) 'limit': '$limit',
        },
      ),
    );
    return (
      items: [for (final e in d['items'] as List) _asMap(e)],
      hasMore: d['has_more'] as bool,
    );
  }

  /// `POST /conversations/{id}/read`：标已读到 [seq]（只进不退）。
  Future<({int readSeq, int unread})> markRead(
    int conversationId,
    int seq,
  ) async {
    final d = _asMap(
      await _json(
        'POST',
        '/conversations/$conversationId/read',
        body: {'seq': seq},
      ),
    );
    return (
      readSeq: (d['read_seq'] as num).toInt(),
      unread: (d['unread'] as num).toInt(),
    );
  }

  /// `POST /conversations/read-all`：一键清全部未读，返回实际变更的会话数。
  Future<int> markAllRead() async =>
      (_asMap(await _json('POST', '/conversations/read-all'))['updated'] as num)
          .toInt();

  /// `PUT /blocks/{target}`：拉黑（幂等）。
  Future<void> block(String target) =>
      _json('PUT', '/blocks/${Uri.encodeComponent(target)}');

  /// `DELETE /blocks/{target}`：解除拉黑（幂等）。
  Future<void> unblock(String target) =>
      _json('DELETE', '/blocks/${Uri.encodeComponent(target)}');

  /// `GET /blocks`：我的黑名单一页，按拉黑时间倒序。
  Future<({List<ImBlockItem> items, bool hasMore})> blocks({
    int? offset,
    int? limit,
  }) async {
    final d = _asMap(
      await _json(
        'GET',
        '/blocks',
        query: {
          if (offset != null) 'offset': '$offset',
          if (limit != null) 'limit': '$limit',
        },
      ),
    );
    return (
      items: [
        for (final e in d['items'] as List) ImBlockItem.fromServer(e as Map),
      ],
      hasMore: d['has_more'] as bool,
    );
  }

  /// 关闭底层 HTTP 客户端（只关自己创建的，外部传入的由调用方管理）。
  void close() {
    if (_ownsClient) _client.close();
  }

  // ---------------- 内部 ----------------

  Uri _uri(String path, [Map<String, String>? query]) {
    final u = Uri.parse('$_base$_prefix$path');
    return (query == null || query.isEmpty)
        ? u
        : u.replace(queryParameters: query);
  }

  /// JSON 请求。[body] 为 null 时不带请求体。
  Future<Object?> _json(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) {
    final uri = _uri(path, query);
    final encoded = body == null ? null : jsonEncode(body);
    return _send((token) {
      final r = http.Request(method, uri)
        ..headers['Authorization'] = 'Bearer $token';
      if (encoded != null) {
        r.headers['Content-Type'] = 'application/json; charset=utf-8';
        r.body = encoded;
      }
      return r;
    });
  }

  /// 发请求并返回响应包的 `data`。[build] 每次尝试都重新构造请求（请求对象只能发一次）。
  ///
  /// HTTP 401 + `IM_TOKEN_INVALID` 时换令牌后重试一次；再失败照常抛。
  /// 换令牌时 `tokenProvider` 抛的异常（含 [ImKickedOutException]）原样上抛。
  Future<Object?> _send(_Build build) async {
    var token = await _tokens.current();
    try {
      return await _once(build(token));
    } on ImApiException catch (e) {
      if (e.httpStatus != 401 || !e.isTokenInvalid) rethrow;
    }
    token = await _tokens.refresh(stale: token);
    return _once(build(token));
  }

  Future<Object?> _once(http.BaseRequest req) async {
    final http.Response res;
    try {
      res = await _client
          .send(req)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on TimeoutException {
      throw ImApiException('NETWORK', '请求超时（${timeout.inSeconds} 秒）', 0);
    } on http.ClientException catch (e) {
      // io 端的 SocketException 会被 http 包包成 ClientException，这里不必 import dart:io（保持 Web 可编译）。
      throw ImApiException('NETWORK', e.message, 0);
    } on Exception catch (e) {
      // TLS 握手失败等其他传输层异常。
      throw ImApiException('NETWORK', e.toString(), 0);
    }
    return _parse(res);
  }

  Object? _parse(http.Response res) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map || !decoded.containsKey('code')) {
      throw ImApiException(
        'BAD_RESPONSE',
        '响应不是合法的响应包（HTTP ${res.statusCode}）',
        res.statusCode,
      );
    }
    final code = decoded['code'];
    // 成功时 code 是数字 0；失败时是字符串错误码。不能用 "0" 判断。
    if (code is num && code == 0) return decoded['data'];
    throw ImApiException(
      code.toString(),
      (decoded['message'] as String?) ?? '',
      res.statusCode,
    );
  }

  static Map<String, dynamic> _asMap(Object? v) =>
      v == null ? <String, dynamic>{} : Map<String, dynamic>.from(v as Map);
}
