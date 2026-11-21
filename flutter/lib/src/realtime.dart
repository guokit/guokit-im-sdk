/// 长连接：抽一层 [ImRealtime] 接口，默认实现包装 centrifuge 0.21，测试注入假实现。
///
/// centrifuge 0.21 的几个事实（按源码核实）：
/// - 固定 Protobuf 传输，服务端订阅的 publication 的 data 是字节，内容是 UTF-8 JSON；
/// - 收到 disconnected 即表示不会自动重连（会自动重连时只发 connecting）；3500 / 3503 都不重连；
/// - 3500 不触发 getToken、也不清旧令牌，要手动 `setToken(new)` + `connect()`；
/// - **监听回调里抛异常会让客户端以 badProtocol 断开且不重连**，所以这里每个监听器都 try/catch，
///   再经异步的 broadcast 流转出去——下游监听器里的异常到不了 centrifuge。
library;

import 'dart:async';
import 'dart:convert';

import 'package:centrifuge/centrifuge.dart' as centrifuge;

/// 长连接事件。
sealed class ImRealtimeEvent {
  const ImRealtimeEvent();
}

/// 正在连接 / 正在自动重连。
class ImRealtimeConnecting extends ImRealtimeEvent {
  const ImRealtimeConnecting();
}

/// 已连上（首连与每次重连成功）。
class ImRealtimeConnected extends ImRealtimeEvent {
  const ImRealtimeConnected();
}

/// 已断开且不会自动重连。[code]：3500 令牌无效、3503 被封或被踢、0 主动断开，其余见 centrifuge。
class ImRealtimeDisconnected extends ImRealtimeEvent {
  const ImRealtimeDisconnected(this.code, this.reason);
  final int code;
  final String reason;
}

/// 一条推送，[data] 已解码（`{"event": "message" | "read" | "read_all", …}`）。
class ImRealtimePublication extends ImRealtimeEvent {
  const ImRealtimePublication(this.data);
  final Map<String, dynamic> data;
}

/// 长连接抽象。一个实例对应一次登录，[close] 后不再使用。
abstract class ImRealtime {
  /// 事件流（broadcast，异步投递）。
  Stream<ImRealtimeEvent> get events;

  /// 替换连接令牌，下次 [connect] 生效。
  void setToken(String token);

  Future<void> connect();

  Future<void> disconnect();

  /// 断开并释放资源。
  Future<void> close();
}

/// 由长连接地址与初始令牌创建 [ImRealtime]。
typedef ImRealtimeFactory = ImRealtime Function(String url, String token);

/// 由 HTTP 地址推导长连接地址：https → wss、http → ws，路径接 `/api/im/v1/connect/websocket`。
String imWebSocketUrl(String baseUrl) {
  final u = Uri.parse(baseUrl);
  final path = u.path.endsWith('/')
      ? u.path.substring(0, u.path.length - 1)
      : u.path;
  return u
      .replace(
        scheme: u.scheme == 'http' ? 'ws' : 'wss',
        path: '$path/api/im/v1/connect/websocket',
      )
      .toString();
}

/// centrifuge 实现。
class CentrifugeRealtime implements ImRealtime {
  CentrifugeRealtime(String url, String token)
    : _client = centrifuge.createClient(
        url,
        centrifuge.ClientConfig(token: token),
      ) {
    _subs = [
      _client.connecting.listen((_) => _emit(const ImRealtimeConnecting())),
      _client.connected.listen((_) => _emit(const ImRealtimeConnected())),
      _client.disconnected.listen(
        (e) => _emit(ImRealtimeDisconnected(e.code, e.reason)),
      ),
      _client.publication.listen((e) {
        try {
          final d = jsonDecode(utf8.decode(e.data));
          if (d is Map) {
            _emit(ImRealtimePublication(Map<String, dynamic>.from(d)));
          }
        } catch (_) {
          // 解析不了的推送直接丢弃，不能让异常逃出监听器。
        }
      }),
    ];
  }

  final centrifuge.Client _client;
  final StreamController<ImRealtimeEvent> _events =
      StreamController<ImRealtimeEvent>.broadcast();
  late final List<StreamSubscription<Object?>> _subs;

  void _emit(ImRealtimeEvent e) {
    try {
      if (!_events.isClosed) _events.add(e);
    } catch (_) {}
  }

  @override
  Stream<ImRealtimeEvent> get events => _events.stream;

  @override
  void setToken(String token) => _client.setToken(token);

  @override
  Future<void> connect() => _client.connect();

  @override
  Future<void> disconnect() => _client.disconnect();

  @override
  Future<void> close() async {
    for (final s in _subs) {
      await s.cancel();
    }
    try {
      await _client.close();
    } finally {
      await _events.close();
    }
  }
}
