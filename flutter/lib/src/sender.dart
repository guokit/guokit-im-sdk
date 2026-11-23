/// 发送（spec §3.5）：文本、图片（路径 / 字节）、位置、自定义、重发，以及上传图链接重拉。
///
/// 由门面在登录时构造，一次登录一个实例。所有 `send*` / [ImSender.resend] 都在终态（sent / failed / rejected）
/// 完成，**发送失败不抛异常**，看返回消息的 `status` 与 `errorCode`。
///
/// 除服务端错误码外，SDK 自己会写的 `errorCode`：
/// - `NETWORK`：超时、断网（可重发）；`BAD_RESPONSE`：响应不是合法响应包；
/// - `IMAGE_DECODE`：图片解不出宽高；`FILE_READ`：按路径读文件失败；`IMAGE_MISSING`：重发时原图字节已不在；
/// - `KICKED_OUT`：换令牌时接入方 `tokenProvider` 抛了 [ImKickedOutException]（同时已发 `onKickedOut`）；
/// - `UNKNOWN`：其他意外异常（`errorMessage` 为异常文本）。
library;

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

  final ImImageSizeReader imageSize;

  /// 上传图链接超过这么久就重拉（服务端约 24 小时过期）。
  static const Duration urlMaxAge = Duration(hours: 20);

  static const _uuid = Uuid();

  /// bytes 版图片的原始字节，按 clientMsgId 保留到 sent / rejected（failed 时留着给重发）。
  final Map<String, Uint8List> _bytes = {};
  final Map<String, String> _filenames = {};

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
  Future<String?> imageUrl(ImMessage message) async {
    if (message.type != 'image') return null;
    final m =
        (message.id == null ? null : await store.getMessageById(message.id!)) ??
        message;
    final url = m.content['url'] as String?;
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
        return latest.content['url'] as String?;
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
      if (msg.type == 'image' && !msg.content.containsKey('attachment_id')) {
        msg = await _upload(msg);
      }
      final resp = await api.sendMessage(
        to: msg.to,
        type: msg.type,
        content: msg.type == 'image'
            ? {
                for (final k in ['attachment_id', 'ticket', 'width', 'height'])
                  k: msg.content[k],
              }
            : msg.content,
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

  /// 取字节 → 解宽高 → 上传；成功后把 `{attachment_id, ticket, width, height}` 写回本地，重发时不再上传。
  Future<ImMessage> _upload(ImMessage msg) async {
    final cid = msg.clientMsgId;
    var bytes = _bytes[cid];
    if (bytes == null) {
      final path = msg.localPath;
      if (path == null || !canReadFiles) {
        throw _LocalFailure('IMAGE_MISSING', '原图已不在内存中，无法重发');
      }
      try {
        bytes = await readFileBytes(path);
      } catch (e) {
        throw _LocalFailure('FILE_READ', e.toString());
      }
    }
    final ({int width, int height}) size;
    try {
      size = await imageSize(bytes);
    } catch (e) {
      throw _LocalFailure('IMAGE_DECODE', '无法识别图片：$e');
    }
    final filename =
        _filenames[cid] ??
        (msg.localPath == null ? 'image.jpg' : p.basename(msg.localPath!));
    final up = await api.upload(bytes, filename);
    final withAttachment = msg.copyWith(
      content: {
        'attachment_id': up.attachmentId,
        'ticket': up.ticket,
        'width': size.width,
        'height': size.height,
        'url': up.url,
      },
    );
    return (await store.upsertMessage(withAttachment)).message;
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
  }
}
