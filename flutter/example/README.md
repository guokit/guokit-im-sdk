# guokit_im 示例

登录、会话列表、收发文本与图片的最小示例。真实 App 里令牌由自家后端签发；这里为了能独立运行，从启动参数直接传入一个已签好的令牌。

```bash
flutter run \
  --dart-define=IM_BASE_URL=https://im.example.com \
  --dart-define=IM_USER=u1001 \
  --dart-define=IM_TOKEN=<后端签的令牌> \
  --dart-define=IM_PEER=u1002
```

令牌可以用 PHP SDK 签：`(new Guokit\Im\Client($baseUrl, $apiKey))->issueToken('u1001')['token']`（签之前先 `upsertUser`）。

跑 Web 版时，页面源（如 `http://localhost:8686`）要先加到 IM 后台「IM 设置 → 允许的 Origin」：

```bash
flutter run -d web-server --web-port 8686 --dart-define=...
```
