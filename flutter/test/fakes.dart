import 'dart:async';

import 'package:guokit_im/guokit_im.dart';

/// 假长连接：connect 立即发 connected；当前令牌在 [badTokens] 里则发 3500。
class FakeRealtime implements ImRealtime {
  FakeRealtime(String token) : tokens = [token];
  final List<String> tokens;
  final Set<String> badTokens = {};
  final _ctrl = StreamController<ImRealtimeEvent>.broadcast();
  int connects = 0;

  void emit(ImRealtimeEvent e) => _ctrl.add(e);

  @override
  Stream<ImRealtimeEvent> get events => _ctrl.stream;
  @override
  void setToken(String token) => tokens.add(token);
  @override
  Future<void> connect() async {
    connects++;
    emit(
      badTokens.contains(tokens.last)
          ? const ImRealtimeDisconnected(3500, 'token')
          : const ImRealtimeConnected(),
    );
  }

  @override
  Future<void> disconnect() async {}
  bool closed = false;
  Duration closeDelay = Duration.zero;
  @override
  Future<void> close() async {
    closed = true;
    if (closeDelay > Duration.zero) await Future<void>.delayed(closeDelay);
  }
}
