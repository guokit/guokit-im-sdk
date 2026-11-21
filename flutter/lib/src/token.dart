/// 用户令牌管理：缓存当前令牌，并发换令牌时只调一次 `tokenProvider`。
library;

import 'models.dart';

/// 令牌管理器。HTTP 层（401）与长连接层（断开码 3500）共用一个实例。
class TokenManager {
  TokenManager(this._provider);

  final Future<ImToken> Function() _provider;

  /// 距过期不足这么久就视为过期，主动换新，少吃一次 401。
  static const Duration expiryMargin = Duration(seconds: 60);

  ImToken? _token;
  Future<ImToken>? _inflight;

  /// [clear] 时自增，让清理前发出的换新结果不再写回缓存。
  int _generation = 0;

  /// 当前缓存的令牌（可能已过期），没有为 null。只读，不触发获取。
  ImToken? get cached => _token;

  /// 取可用令牌：有换新在途就等它；缓存为空或快过期就换新；否则直接返回缓存。
  Future<String> current() {
    final t = _token;
    if (_inflight == null &&
        t != null &&
        t.expiresAt.isAfter(DateTime.now().toUtc().add(expiryMargin))) {
      return Future.value(t.token);
    }
    return refresh();
  }

  /// 换新令牌。并发调用共享同一个 Future，只调一次 provider；完成（成功或失败）后清空在途标记。
  ///
  /// [stale]：调用方刚用过、被服务端判失效的那个令牌。若缓存里已经是别的令牌
  /// （别的请求先一步换过了），直接返回缓存，不再调 provider。
  /// 这样「两个请求同时 401」时，不论第二个 401 是在换新途中还是换新之后到达，都只换一次。
  ///
  /// provider 抛 [ImKickedOutException] 或其他异常时原样上抛，缓存保持为空。
  Future<String> refresh({String? stale}) {
    final t = _token;
    if (_inflight == null && stale != null && t != null && t.token != stale) {
      return Future.value(t.token);
    }
    var f = _inflight;
    if (f == null) {
      _token = null;
      final gen = _generation;
      // Future.sync：provider 同步抛异常时也走 Future 的失败路径，不会绕过下面的清理。
      final created = Future.sync(_provider).then((nt) {
        if (gen == _generation) _token = nt;
        return nt;
      });
      _inflight = f = created;
      created.whenComplete(() {
        if (identical(_inflight, created)) _inflight = null;
      }).ignore();
    }
    return f.then((nt) => nt.token);
  }

  /// 清掉缓存（登出时调）。在途的换新不会被取消，已在等它的调用方照常拿到结果，
  /// 但结果不再写回缓存。
  void clear() {
    _generation++;
    _token = null;
    _inflight = null;
  }
}
