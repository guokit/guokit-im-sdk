/// SDK 对外抛出的异常类型。
library;

/// IM 接口调用失败。
///
/// - [code]：服务端的字符串错误码（如 `IM_USER_NOT_FOUND`、`IM_TOKEN_INVALID`），
///   或 SDK 自己的两个码：
///   - `NETWORK`：超时、断网、连接失败等，没拿到 HTTP 响应，此时 [httpStatus] 为 0；
///   - `BAD_RESPONSE`：拿到了响应但不是合法的响应包（如网关返回的 HTML 错误页）。
/// - [message]：服务端的中文说明，或 SDK 给出的原因。
/// - [httpStatus]：HTTP 状态码；业务失败多为 200（见接入文档 §3）。
class ImApiException implements Exception {
  const ImApiException(this.code, this.message, this.httpStatus);

  final String code;
  final String message;
  final int httpStatus;

  /// 令牌缺失 / 过期 / 用户被封或被踢（HTTP 401 `IM_TOKEN_INVALID`）。
  bool get isTokenInvalid => code == 'IM_TOKEN_INVALID';

  /// 没拿到 HTTP 响应（超时、断网等）。
  bool get isNetwork => code == 'NETWORK';

  /// 稍后重试可能成功：网络错误、HTTP 5xx、`IM_RATE_LIMITED`。
  ///
  /// 发送层据此把消息标为可重发的 `failed`（spec §3.5）。
  bool get isTemporary =>
      isNetwork || httpStatus >= 500 || code == 'IM_RATE_LIMITED';

  @override
  String toString() => 'ImApiException($code, HTTP $httpStatus): $message';
}

/// 用户已被封禁或已登出，不应再尝试连接。
///
/// 约定（spec §3.6）：接入方的 `tokenProvider` 发现自家后端判定该用户已封禁 / 已登出时
/// 抛出本异常，SDK 会走 `onKickedOut` 并停止重连。抛其他异常则视为临时失败。
/// SDK 内部对它一律原样上抛，不包装成 [ImApiException]。
class ImKickedOutException implements Exception {
  const ImKickedOutException([this.message = '用户已被封禁或已登出']);

  final String message;

  @override
  String toString() => 'ImKickedOutException: $message';
}
