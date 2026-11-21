# 接入方后端参考

> **PHP 首选 SDK**：[php/README.md](../../../php/README.md)（`guokit/im`，含回调验签）。
> 本页的手写片段给暂时没有 SDK 的语言（Go / Node / Java）参考。

前缀 `https://<IM 域名>/api/im/v1/server`，请求头 `X-Api-Key: imk_…`。响应 `{"code":0,"message":"ok","data":{…}}`，失败时 `code` 为字符串。
下面片段是最小可用形态，演示正确的调用与判定方式；生产代码请补超时、重试与日志。字段以 `docs/IM接入文档.md` §4、§8 为准。

## 1. 调用封装与签令牌

用户登录成功后：先同步资料（不存在即创建），再签令牌下发客户端。令牌是不透明字符串，客户端以 `expires_at` 判断何时续签。

### PHP（Guzzle）

```php
use GuzzleHttp\Client;

function imCall(string $method, string $path, ?array $json = null): array {
    static $http;
    $http ??= new Client(['base_uri' => getenv('IM_BASE_URL'), 'timeout' => 5, 'http_errors' => false]);
    $opt = ['headers' => ['X-Api-Key' => getenv('IM_API_KEY')]];
    if ($json !== null) $opt['json'] = $json;
    $res = $http->request($method, '/api/im/v1/server' . $path, $opt);
    return json_decode((string) $res->getBody(), true) ?: ['code' => 'INTERNAL', 'message' => 'bad response'];
}

$uid = (string) $user->id;
imCall('PUT', '/users/' . rawurlencode($uid), ['nickname' => $user->nickname, 'avatar_url' => $user->avatar]);
$r = imCall('POST', '/users/' . rawurlencode($uid) . '/token');
if ($r['code'] !== 0) {                       // 严格比较：成功是数字 0
    throw new RuntimeException("IM 签令牌失败：{$r['code']} {$r['message']}");
}
return ['im_token' => $r['data']['token'], 'im_expires_at' => $r['data']['expires_at']];
```

### Go

```go
type imResp struct {
	Code    any             `json:"code"` // 成功是数字 0，失败是字符串
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

func imCall(ctx context.Context, method, path string, body any) (*imResp, error) {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequestWithContext(ctx, method, os.Getenv("IM_BASE_URL")+"/api/im/v1/server"+path, rd)
	req.Header.Set("X-Api-Key", os.Getenv("IM_API_KEY"))
	req.Header.Set("Content-Type", "application/json")
	res, err := (&http.Client{Timeout: 5 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	var r imResp
	if err := json.NewDecoder(res.Body).Decode(&r); err != nil {
		return nil, err
	}
	return &r, nil
}

func (r *imResp) OK() bool { n, ok := r.Code.(float64); return ok && n == 0 }

// 签令牌
r, err := imCall(ctx, "POST", "/users/"+url.PathEscape(uid)+"/token", nil)
if err != nil {
	return fmt.Errorf("IM 签令牌请求失败：%w", err)
}
if !r.OK() {
	return fmt.Errorf("IM 签令牌失败：%v %s", r.Code, r.Message)
}
var tok struct {
	Token     string `json:"token"`
	ExpiresAt string `json:"expires_at"` // "2026-11-27 10:00:00"，Asia/Shanghai
}
if err := json.Unmarshal(r.Data, &tok); err != nil {
	return err
}
```

### Node.js（18+，内置 fetch）

```js
async function imCall(method, path, body) {
  const res = await fetch(`${process.env.IM_BASE_URL}/api/im/v1/server${path}`, {
    method,
    headers: { 'X-Api-Key': process.env.IM_API_KEY, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(5000),
  });
  return res.json();
}

await imCall('PUT', `/users/${encodeURIComponent(uid)}`, { nickname, avatar_url: avatar });
const r = await imCall('POST', `/users/${encodeURIComponent(uid)}/token`);
if (r.code !== 0) throw new Error(`IM 签令牌失败：${r.code} ${r.message}`);
return { imToken: r.data.token, imExpiresAt: r.data.expires_at };
```

### Java（11+，java.net.http）

```java
HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

String imCall(String method, String path, String jsonBody) throws Exception {
    HttpRequest.Builder b = HttpRequest.newBuilder(URI.create(System.getenv("IM_BASE_URL") + "/api/im/v1/server" + path))
        .timeout(Duration.ofSeconds(5))
        .header("X-Api-Key", System.getenv("IM_API_KEY"))
        .header("Content-Type", "application/json")
        .method(method, jsonBody == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(jsonBody));
    return http.send(b.build(), HttpResponse.BodyHandlers.ofString()).body();
}
// 解析后判定：code 是数字节点且值为 0 才算成功（Jackson：node.get("code").isInt() && node.get("code").asInt() == 0）
```

## 2. 常用服务端操作

| 场景 | 调用 |
|---|---|
| 批量导入存量用户 | `POST /users/batch` `{"users":[{"user_id","nickname","avatar_url"}]}`，每批 1–100，任一不合法整批拒绝 |
| 封号 / 解封 | `PATCH /users/{user_id}` `{"status":0}` / `{"status":1}`；封号让全部令牌立即失效并断开连接，解封后要重新签令牌 |
| 退出全部设备 | `POST /users/{user_id}/kick` |
| 自家拉黑后同步 | `PUT /users/{user_id}/blocks/{target}`；解除 `DELETE` 同路径；幂等，失败可直接重试 |
| 以某用户身份发消息 | `POST /messages`，请求体同客户端发消息再加 `from`；from / to 不能是 `@cs` |
| 审计查历史 | `GET /conversations/{id}/messages` |

黑名单以接入方为准时：在自家拉黑事务提交后调 IM；IM 调用失败就记一条待重试任务，不要回滚自家拉黑。

## 3. 回调验签

签名 `hex(HMAC-SHA256(回调密钥, X-Im-Timestamp + "\n" + 原始请求体))`。三件事缺一不可：**原始请求体**、**常量时间比较**、**时间戳 5 分钟窗口**。
after_send 按 `X-Im-Delivery-Id` 去重；before_send 显式回 `allow: true`。

### PHP

```php
$body = file_get_contents('php://input');
$ts   = $_SERVER['HTTP_X_IM_TIMESTAMP'] ?? '';
$sig  = $_SERVER['HTTP_X_IM_SIGNATURE'] ?? '';
if (!ctype_digit($ts) || abs(time() - (int) $ts) > 300
    || !hash_equals(hash_hmac('sha256', $ts . "\n" . $body, getenv('IM_CALLBACK_SECRET')), $sig)) {
    http_response_code(401); exit;
}
```

### Go

```go
func verifyIM(r *http.Request, secret string) ([]byte, bool) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		return nil, false
	}
	ts := r.Header.Get("X-Im-Timestamp")
	sec, err := strconv.ParseInt(ts, 10, 64)
	if err != nil || math.Abs(float64(time.Now().Unix()-sec)) > 300 {
		return nil, false
	}
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(ts + "\n"))
	m.Write(body)
	want := hex.EncodeToString(m.Sum(nil))
	return body, hmac.Equal([]byte(want), []byte(r.Header.Get("X-Im-Signature")))
}
```

### Node.js（Express：路由上用 `express.raw({ type: 'application/json' })` 拿原始体）

```js
const crypto = require('node:crypto');

function verifyIM(req, secret) {
  const ts = req.get('X-Im-Timestamp') || '';
  if (!/^\d+$/.test(ts) || Math.abs(Date.now() / 1000 - Number(ts)) > 300) return false;
  const want = crypto.createHmac('sha256', secret).update(ts + '\n').update(req.body).digest('hex');
  const a = Buffer.from(want);
  const b = Buffer.from(req.get('X-Im-Signature') || '');
  return a.length === b.length && crypto.timingSafeEqual(a, b);   // 先比字节长度，否则 timingSafeEqual 会抛错
}
```

### Java

```java
boolean verifyIM(String ts, String sig, byte[] rawBody, String secret) throws Exception {
    if (ts == null || !ts.matches("\\d+") || Math.abs(Instant.now().getEpochSecond() - Long.parseLong(ts)) > 300) return false;
    Mac mac = Mac.getInstance("HmacSHA256");
    mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
    mac.update((ts + "\n").getBytes(StandardCharsets.UTF_8));
    String want = HexFormat.of().formatHex(mac.doFinal(rawBody));          // Java 17+
    return sig != null && MessageDigest.isEqual(want.getBytes(StandardCharsets.UTF_8), sig.getBytes(StandardCharsets.UTF_8));
}
```

响应：before_send 回 `{"code":0,"data":{"allow":true}}` 或 `{"code":0,"data":{"allow":false,"reason":"…"}}`；after_send 回 `{"code":0}`。
