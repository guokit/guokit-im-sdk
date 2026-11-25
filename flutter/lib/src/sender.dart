/// 发送（spec §3.5）：文本、图片、语音、文件与视频（路径 / 字节）、位置、自定义、重发，以及上传的附件链接重拉。
///
/// 由门面在登录时构造，一次登录一个实例。所有 `send*` / [ImSender.resend] 都在终态（sent / failed / rejected）
/// 完成，**发送失败不抛异常**，看返回消息的 `status` 与 `errorCode`。
///
/// 除服务端错误码外，SDK 自己会写的 `errorCode`：
/// - `NETWORK`：超时、断网（可重发）；`BAD_RESPONSE`：响应不是合法响应包；
/// - `IMAGE_DECODE`：图片解不出宽高；`FILE_READ`：按路径读文件失败；`IMAGE_MISSING` / `VOICE_MISSING` / `FILE_MISSING` / `VIDEO_MISSING`：重发时内容的字节已不在；
/// - `KICKED_OUT`：换令牌时接入方 `tokenProvider` 抛了 [ImKickedOutException]（同时已发 `onKickedOut`）；
/// - `UNKNOWN`：其他意外异常（`errorMessage` 为异常文本）。
library;

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'errors.dart';
import 'file_reader.dart';
import 'models.dart';
import 'store.dart';
import 'sync.dart';

/// 取图片宽高。
typedef ImImageSizeReader =
    Future<({int width, int height})> Function(Uint8List bytes);

/// 默认用 `dart:ui` 解码第一帧取宽高。
Future<({int width, int height})> decodeImageSize(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    final size = (width: frame.image.width, height: frame.image.height);
    frame.image.dispose();
    return size;
  } finally {
    codec.dispose();
  }
}

/// 本地失败（不经服务端）。
class _LocalFailure implements Exception {
  _LocalFailure(this.code, this.message);
  final String code;
  final String message;
}

class ImSender {
  ImSender({
    required this.api,
    required this.store,
    required this.sync,
    required this.me,
    required this.onUpdated,
    required this.onSnapshot,
    required this.onKickedOut,
    required this.onProgress,
    this.imageSize = decodeImageSize,
  });

  final ImApi api;
  final ImStore store;
  final ImSync sync;
  final String me;

  /// 发 `onMessageUpdated`。
  final void Function(ImMessage) onUpdated;

  /// 推会话快照与总未读。
  final Future<void> Function() onSnapshot;

  /// 走踢下线流程（发 `onKickedOut`、停止重连）。
  final void Function() onKickedOut;

  /// 发 `onSendProgress`。
  final void Function(ImSendProgress) onProgress;

  final ImImageSizeReader imageSize;

  /// 上传的附件链接超过这么久就重拉（服务端约 24 小时过期）。
  static const Duration urlMaxAge = Duration(hours: 20);

  static const _uuid = Uuid();

  /// bytes 版附件的原始字节，按 clientMsgId 保留到 sent / rejected（failed 时留着给重发）。
  final Map<String, Uint8List> _bytes = {};
  final Map<String, String> _filenames = {};

  /// 视频封面的字节，按 clientMsgId 保留到传上去为止；只在内存，进程重启后没有，重发就不带封面。
  final Map<String, Uint8List> _covers = {};

  Future<ImMessage> sendText(String to, String text) =>
      _sendNew(to, 'text', {'text': text});

  Future<ImMessage> sendLocation(
    String to,
    double lat,
    double lng, {
    String? name,
    String? address,
  }) => _sendNew(to, 'location', {
    'lat': lat,
    'lng': lng,
    'name': ?name,
    'address': ?address,
  });

  /// [data] 必须是 JSON 对象（服务端要求），[desc] 用于会话预览与离线推送文字。
  Future<ImMessage> sendCustom(
    String to,
    Map<String, dynamic> data,
    String desc,
  ) => _sendNew(to, 'custom', {'data': data, 'desc': desc});

  /// 按路径发图（io 端）。重发时按 `localPath` 重读。
  Future<ImMessage> sendImage(String to, String filePath) {
    if (!canReadFiles) {
      throw UnsupportedError('当前平台不能按路径读文件，请用 sendImageBytes');
    }
    return _sendNew(to, 'image', {}, localPath: filePath);
  }

  /// 按字节发图（Web 必须用这个）。字节在内存里保留到终态，失败后可重发。
  Future<ImMessage> sendImageBytes(
    String to,
    Uint8List bytes, {
    String filename = 'image.jpg',
  }) {
    final cid = _uuid.v4();
    _bytes[cid] = bytes;
    _filenames[cid] = filename;
    return _sendNew(to, 'image', {}, clientMsgId: cid);
  }

  /// 按路径发语音（io 端）。[duration] 为录音时长，四舍五入到秒。重发时按 `localPath` 重读。
  Future<ImMessage> sendVoice(String to, String filePath, Duration duration) {
    if (!canReadFiles) {
      throw UnsupportedError('当前平台不能按路径读文件，请用 sendVoiceBytes');
    }
    return _sendNew(to, 'voice', {
      'duration': _seconds(duration, 60, '语音'),
    }, localPath: filePath);
  }

  /// 按字节发语音（Web 必须用这个）。字节在内存里保留到终态，失败后可重发。
  Future<ImMessage> sendVoiceBytes(
    String to,
    Uint8List bytes,
    Duration duration, {
    String filename = 'voice.m4a',
  }) {
    final seconds = _seconds(duration, 60, '语音');
    final cid = _uuid.v4();
    _bytes[cid] = bytes;
    _filenames[cid] = filename;
    return _sendNew(to, 'voice', {'duration': seconds}, clientMsgId: cid);
  }

  /// 按路径发文件（io 端），边读边传。[name] 缺省取路径里的文件名，扩展名要和内容对得上。重发时按 `localPath` 重读。
  Future<ImMessage> sendFile(String to, String filePath, {String? name}) {
    if (!canReadFiles) {
      throw UnsupportedError('当前平台不能按路径读文件，请用 sendFileBytes');
    }
    return _sendNew(to, 'file', {
      'name': name ?? p.basename(filePath),
    }, localPath: filePath);
  }

  /// 按字节发文件（Web 必须用这个）。字节在内存里保留到终态，失败后可重发。
  Future<ImMessage> sendFileBytes(
    String to,
    Uint8List bytes, {
    required String name,
  }) {
    final cid = _uuid.v4();
    _bytes[cid] = bytes;
    return _sendNew(to, 'file', {'name': name}, clientMsgId: cid);
  }

  /// 按路径发视频（io 端），边读边传。[duration] 四舍五入到秒；[coverBytes] 是封面图片。重发时按 `localPath` 重读。
  Future<ImMessage> sendVideo(
    String to,
    String filePath, {
    required Duration duration,
    required int width,
    required int height,
    Uint8List? coverBytes,
  }) {
    if (!canReadFiles) {
      throw UnsupportedError('当前平台不能按路径读文件，请用 sendVideoBytes');
    }
    final content = _videoContent(duration, width, height);
    final cid = _uuid.v4();
    if (coverBytes != null) _covers[cid] = coverBytes;
    return _sendNew(
      to,
      'video',
      content,
      clientMsgId: cid,
      localPath: filePath,
    );
  }

  /// 按字节发视频（Web 必须用这个）。字节在内存里保留到终态，失败后可重发。
  Future<ImMessage> sendVideoBytes(
    String to,
    Uint8List bytes, {
    required Duration duration,
    required int width,
    required int height,
    Uint8List? coverBytes,
    String filename = 'video.mp4',
  }) {
    final content = _videoContent(duration, width, height);
    final cid = _uuid.v4();
    _bytes[cid] = bytes;
    _filenames[cid] = filename;
    if (coverBytes != null) _covers[cid] = coverBytes;
    return _sendNew(to, 'video', content, clientMsgId: cid);
  }

  static Map<String, dynamic> _videoContent(Duration d, int w, int h) {
    if (w < 1 || w > 20000 || h < 1 || h > 20000) {
      throw ArgumentError('视频宽高须为 1–20000（当前 $w×$h）');
    }
    return {'duration': _seconds(d, 3600, '视频'), 'width': w, 'height': h};
  }

  /// 时长取整秒；不足 1 秒算 1 秒，超过 [max] 秒抛 [ArgumentError]。
  static int _seconds(Duration d, int max, String what) {
    final s = (d.inMilliseconds / 1000).round();
    if (d <= Duration.zero || s > max) {
      throw ArgumentError.value(d, 'duration', '$what时长须在 $max 秒以内');
    }
    return s < 1 ? 1 : s;
  }

  /// 重发一条 failed 消息，沿用原 clientMsgId（服务端幂等）。rejected 不允许重发。
  Future<ImMessage> resend(ImMessage failed) async {
    if (failed.status != ImMessageStatus.failed || !failed.isSelf) {
      throw ArgumentError('只能重发本人的 failed 消息（当前 ${failed.status.name}）');
    }
    final current =
        await store.getMessageByClientMsgId(me, failed.clientMsgId) ?? failed;
    if (current.status == ImMessageStatus.sent) return current;
    final local = current.copyWith(
      status: ImMessageStatus.sending,
      errorCode: null,
      errorMessage: null,
    );
    await store.upsertMessage(local);
    onUpdated(local);
    return _deliver(local);
  }

  /// 图片可用地址：非图片 null；外链图原样返回；上传图链接为空或取得超过 [urlMaxAge] 时重拉这条消息，
  /// 更新本地并发 `onMessageUpdated` 后返回新地址。重拉失败返回旧地址，不抛。
  /// 未确认（发送中 / 失败）的上传图没有会话可重拉，返回上传时拿到的临时链接（约 24 小时有效）；
  /// 按路径发的图在本机优先用 `localPath` 显示。
  Future<String?> imageUrl(ImMessage message) async =>
      message.type == 'image' ? _mediaUrl(message, 'url') : null;

  /// 语音可用地址，规则同 [imageUrl]；非语音 null。
  Future<String?> voiceUrl(ImMessage message) async =>
      message.type == 'voice' ? _mediaUrl(message, 'url') : null;

  /// 文件下载地址（下载下来是原文件名），规则同 [imageUrl]；非文件 null。
  Future<String?> fileUrl(ImMessage message) async =>
      message.type == 'file' ? _mediaUrl(message, 'url') : null;

  /// 视频可用地址，规则同 [imageUrl]；非视频 null。
  Future<String?> videoUrl(ImMessage message) async =>
      message.type == 'video' ? _mediaUrl(message, 'url') : null;

  /// 视频封面可用地址，规则同 [imageUrl]；非视频、没有封面 null。
  Future<String?> videoCoverUrl(ImMessage message) async {
    // 没有封面时服务端给的 cover_attachment_id 是 0、cover_url 是空串，不能当成链接过期去重拉。
    final cover = message.type == 'video'
        ? message.content['cover_attachment_id']
        : null;
    return cover == null || cover == 0 ? null : _mediaUrl(message, 'cover_url');
  }

  Future<String?> _mediaUrl(ImMessage message, String key) async {
    final m =
        (message.id == null ? null : await store.getMessageById(message.id!)) ??
        message;
    final url = m.content[key] as String?;
    if (!m.content.containsKey('attachment_id')) return url;
    final convId = m.conversationId;
    final seq = m.seq;
    if (convId == null || seq == null) return url;
    final fetched = m.urlFetchedAt;
    if (url != null &&
        url.isNotEmpty &&
        fetched != null &&
        DateTime.now().toUtc().difference(fetched) < urlMaxAge) {
      return url;
    }
    try {
      final r = await api.messages(convId, afterSeq: seq - 1, limit: 1);
      await sync.ingest(convId, r.items, notify: false);
      final latest = m.id == null
          ? await store.getMessageByClientMsgId(m.from, m.clientMsgId)
          : await store.getMessageById(m.id!);
      if (latest != null) {
        onUpdated(latest);
        return latest.content[key] as String?;
      }
    } on ImKickedOutException {
      onKickedOut();
    } catch (_) {
      // 重拉失败：返回旧地址。
    }
    return url;
  }

  // ---------------- 内部 ----------------

  Future<ImMessage> _sendNew(
    String to,
    String type,
    Map<String, dynamic> content, {
    String? clientMsgId,
    String? localPath,
  }) async {
    final local = ImMessage(
      clientMsgId: clientMsgId ?? _uuid.v4(),
      conversationId: (await store.conversationByPeer(to))?.id,
      from: me,
      to: to,
      isSelf: true,
      type: type,
      content: content,
      status: ImMessageStatus.sending,
      createdAt: DateTime.now().toUtc(),
      localPath: localPath,
    );
    await store.upsertMessage(local);
    onUpdated(local);
    return _deliver(local);
  }

  /// 从 sending 走到终态。任何异常都转成 failed / rejected，不往外抛。
  Future<ImMessage> _deliver(ImMessage local) async {
    try {
      return await _deliverInner(local);
    } catch (e) {
      // 兜底（如登出后存储已关闭）：不落库，直接返回失败版本。
      return local.copyWith(
        status: ImMessageStatus.failed,
        errorCode: 'UNKNOWN',
        errorMessage: e.toString(),
      );
    }
  }

  Future<ImMessage> _deliverInner(ImMessage local) async {
    var msg = local;
    try {
      if (_media.containsKey(msg.type) &&
          !msg.content.containsKey('attachment_id')) {
        msg = await _uploadCover(msg); // 分两步各自落库：正文失败时，传好的封面不丢
        msg = await _upload(msg);
      }
      final resp = await api.sendMessage(
        to: msg.to,
        type: msg.type,
        content: switch (_media[msg.type]) {
          final keys? => {
            for (final k in keys)
              if (msg.content[k] != null) k: msg.content[k],
          },
          null => msg.content,
        },
        clientMsgId: msg.clientMsgId,
      );
      final r = await store.upsertMessage(
        ImMessage.fromServer(resp, me: me, peerId: msg.to),
      );
      _forget(msg.clientMsgId);
      onUpdated(r.message);
      await onSnapshot();
      return r.message;
    } on ImKickedOutException catch (e) {
      onKickedOut();
      return _finish(msg, ImMessageStatus.failed, 'KICKED_OUT', e.message);
    } on ImApiException catch (e) {
      final rejected =
          e.code == 'IM_BLOCKED' || e.code == 'IM_MESSAGE_REJECTED';
      return _finish(
        msg,
        rejected ? ImMessageStatus.rejected : ImMessageStatus.failed,
        e.code,
        e.message,
      );
    } on _LocalFailure catch (e) {
      return _finish(msg, ImMessageStatus.failed, e.code, e.message);
    } catch (e) {
      // 其余异常（多为 tokenProvider 自家接口断网）按临时失败处理：落库为 failed 并发事件，可重发。
      return _finish(msg, ImMessageStatus.failed, 'NETWORK', e.toString());
    }
  }

  /// 要先上传的类型 → 发送时 content 带哪些键。
  static const _media = {
    'image': ['attachment_id', 'ticket', 'width', 'height'],
    'voice': ['attachment_id', 'ticket', 'duration'],
    'file': ['attachment_id', 'ticket', 'name'],
    'video': [
      'attachment_id',
      'ticket',
      'duration',
      'width',
      'height',
      'cover_attachment_id',
      'cover_ticket',
    ],
  };

  /// 内容的字节已不在、又没有本地路径可读时的错误。
  static const _missing = {
    'image': ('IMAGE_MISSING', '原图已不在内存中，无法重发'),
    'voice': ('VOICE_MISSING', '语音已不在内存中，无法重发'),
    'file': ('FILE_MISSING', '文件已不在内存中，无法重发'),
    'video': ('VIDEO_MISSING', '视频已不在内存中，无法重发'),
  };

  static const _defaultNames = {
    'image': 'image.jpg',
    'voice': 'voice.m4a',
    'video': 'video.mp4',
  };

  /// 上传视频封面，成功后写回本地，重发时不再传。没有封面、或已传过的原样返回。
  /// 服务端不收这张封面就不带封面继续发（再试也一样）；网络等其他失败照常上抛，重发时再传。
  Future<ImMessage> _uploadCover(ImMessage msg) async {
    final cid = msg.clientMsgId;
    final cover = _covers[cid];
    if (cover == null) return msg;
    try {
      final up = await api.upload(() async => _bytesBody(cover), 'cover.jpg');
      final withCover = msg.copyWith(
        content: {
          ...msg.content,
          'cover_attachment_id': up.attachmentId,
          'cover_ticket': up.ticket,
          'cover_url': up.url,
        },
      );
      final saved = (await store.upsertMessage(withCover)).message;
      _covers.remove(cid);
      return saved;
    } on ImApiException catch (e) {
      if (e.code != 'VALIDATION') rethrow;
      _covers.remove(cid);
      return msg;
    }
  }

  /// 取内容 →（图片解宽高）→ 上传；成功后把附件 id、凭证等写回本地，重发时不再上传。
  /// 按路径发的文件、视频边读边传，其余整个读进内存。
  Future<ImMessage> _upload(ImMessage msg) async {
    final cid = msg.clientMsgId;
    final type = msg.type;
    final path = canReadFiles ? msg.localPath : null;
    final streamed = type == 'file' || type == 'video';
    var bytes = _bytes[cid];
    if (bytes == null) {
      if (path == null) {
        final (code, message) = _missing[type]!;
        throw _LocalFailure(code, message);
      }
      if (!streamed) bytes = await _read(() => readFileBytes(path));
    }
    ({int width, int height})? size;
    if (type == 'image') {
      try {
        size = await imageSize(bytes!);
      } catch (e) {
        throw _LocalFailure('IMAGE_DECODE', '无法识别图片：$e');
      }
    }
    final filename =
        msg.fileName ??
        _filenames[cid] ??
        (path == null ? _defaultNames[type]! : p.basename(path));
    var total = 0;
    var active = true; // 超时后底层请求还在传，不再报它的进度
    try {
      final up = await api.upload(
        () async {
          final body = bytes == null
              ? (
                  length: await _read(() => fileLength(path!)),
                  stream: openFile(path!),
                )
              : _bytesBody(bytes);
          total = body.length;
          return body;
        },
        filename,
        kind: type,
        onProgress: (sent, total) {
          if (!active) return;
          onProgress(
            ImSendProgress(clientMsgId: cid, sent: sent, total: total),
          );
        },
      );
      final withAttachment = msg.copyWith(
        content: {
          ...msg.content,
          'attachment_id': up.attachmentId,
          'ticket': up.ticket,
          if (size != null) ...{'width': size.width, 'height': size.height},
          if (streamed) 'size': total,
          'url': up.url,
        },
      );
      return (await store.upsertMessage(withAttachment)).message;
    } finally {
      active = false;
    }
  }

  static ImUploadBody _bytesBody(Uint8List bytes) => (
    length: bytes.length,
    stream: Stream.fromIterable([
      // 分块只为进度看得出变化，不复制字节
      for (var i = 0; i < bytes.length; i += 65536)
        Uint8List.sublistView(bytes, i, min(i + 65536, bytes.length)),
    ]),
  );

  static Future<T> _read<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      throw _LocalFailure('FILE_READ', e.toString());
    }
  }

  Future<ImMessage> _finish(
    ImMessage msg,
    ImMessageStatus status,
    String code,
    String message,
  ) async {
    final r = await store.upsertMessage(
      msg.copyWith(status: status, errorCode: code, errorMessage: message),
    );
    // 推送可能已先把它合并成 sent，store 不会降级，以落库结果为准。
    if (r.message.status != ImMessageStatus.failed) _forget(msg.clientMsgId);
    onUpdated(r.message);
    return r.message;
  }

  void _forget(String cid) {
    _bytes.remove(cid);
    _filenames.remove(cid);
    _covers.remove(cid);
  }
}
