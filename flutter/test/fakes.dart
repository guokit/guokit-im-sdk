import 'dart:async';

import 'package:guokit_im/guokit_im.dart';

/// 假长连接：connect 立即发 connected。
class FakeRealtime implements ImRealtime {
  FakeRealtime(String token) : tokens = [token];
  final List<String> tokens;
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
    emit(const ImRealtimeConnected());
  }

  @override
  Future<void> disconnect() async {}
  @override
  Future<void> close() async {}
}
