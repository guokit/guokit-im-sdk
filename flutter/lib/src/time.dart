/// 服务端时间字符串与 [DateTime] 的互转。
///
/// 服务端所有时间（`created_at`、`last_msg_at`、`expires_at`）都是
/// `YYYY-MM-DD HH:mm:ss`，不带时区，固定东八区（Asia/Shanghai，无夏令时）。
/// 不能直接 `DateTime.parse`：那样会被当成设备本地时间，设备不在东八区时就错了。
library;

final RegExp _cstPattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$',
);

/// 把东八区无时区字符串解析成 UTC [DateTime]。
///
/// `"2026-11-20 10:00:00"` → `2026-11-20T02:00:00.000Z`。格式不对抛 [FormatException]。
DateTime parseCst(String s) {
  final m = _cstPattern.firstMatch(s);
  if (m == null) {
    throw FormatException('时间格式应为 YYYY-MM-DD HH:mm:ss', s);
  }
  int g(int i) => int.parse(m.group(i)!);
  // DateTime.utc 会把小时减 8 后的负数自动借位到前一天。
  return DateTime.utc(g(1), g(2), g(3), g(4) - 8, g(5), g(6));
}

/// 把任意 [DateTime] 格式化成东八区 `YYYY-MM-DD HH:mm:ss`（秒以下截断）。
String formatCst(DateTime t) {
  final c = t.toUtc().add(const Duration(hours: 8));
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${p(c.year, 4)}-${p(c.month)}-${p(c.day)} '
      '${p(c.hour)}:${p(c.minute)}:${p(c.second)}';
}
