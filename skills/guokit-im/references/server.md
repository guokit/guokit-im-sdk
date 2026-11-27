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
| 查会话设置 | `GET /users/{user_id}/conversations/{peer_id}`，对方为 `@cs` 或 `@cs:<主体标识>` 即客服会话；查不到 404 + `VALIDATION`；返回 `{conversation_id, peer_user_id, pinned, pinned_at, muted, clear_seq, unread, visible}` |
| 置顶 / 免打扰 | `PUT /users/{user_id}/conversations/{peer_id}/settings` `{"pinned"?:bool,"muted"?:bool}`，至少一个 |
| 清空聊天记录 | `POST /users/{user_id}/conversations/{peer_id}/clear`，只清该用户这一侧 |
| 删除会话 | `DELETE /users/{user_id}/conversations/{peer_id}`：清空 + 移出列表 + 取消置顶，免打扰保留 |
| 以某用户身份发消息 | `POST /messages`，请求体同客户端发消息再加 `from`；from / to 不能是客服 |
| 审计查历史 | `GET /conversations/{id}/messages` |
| 查用户是否在线 | `POST /users/online` `{"user_ids":[…]}`，每次 1–100 个，返回 `items[{user_id, online}]`；在线 = 此刻至少一条长连接，这是权威来源 |
| 撤回违规消息 | `POST /messages/{id}/recall`，不限时，返回撤回后的消息对象；渠道用户的会话、平台客服发的消息按不存在，客服主体的坐席发的可以撤（404 `VALIDATION`）。撤回后异步收 `message_recalled` 回调 `{message_id, conversation_id, seq, from, to, by, recalled_at, from_source, to_source}`（不带原文），可能比 after_send 先到，按 `message_id` 判断 |
| 收上下线通知 | IM 设置打开「推送用户上下线」后收 `user_state` 回调 `{user_id, online, at, ts}`；下线在断开 30 秒后才推；按 `ts` 保留最新，重启不补发下线，以查询为准 |
| 识别微信用户是哪个会员 | IM 设置打开「识别微信用户」后收同步回调 `resolve_user` `{channel, account_type, appid, openid, unionid}`，3 秒内回 `{"code":0,"data":{"user_id":"u1001"}}`；不认识回空串。只返回**已确认绑定且已导入**的会员，不要按昵称、手机号猜；查询出错回非 0 的 `code`，别回空串（空串会清掉已有关联） |
| 每家门店 / 商户一个客服 | `PUT /api/imcs/v1/server/services/{sid}` `{"name"}` 建主体，`PUT …/services/{sid}/agents/{external_id}` `{"nickname"}` 加员工，首次用 `POST …/services/batch` 批量导入；用户给 `@cs:<sid>` 发消息。员工打开工作台前 `POST …/agents/{external_id}/token` 签坐席令牌（**先自己确认他有权限**），页面嵌 `/imcs-widget/desk-loader.js`，App 里 WebView 打开 `/imcs-desk#token=…`。员工不在线靠 after_send 的 `service_id`、`agents_online`、`agent_external_id`、`agent_online` 推手机。员工名单对账用 `PUT …/services/{sid}/agents` 整份替换、`GET …/agents`、`GET …/services`，没人回的用 `GET …/sessions` 查，接待变化可收 `cs_session` 回调；坐席的回复走 before_send（`from` 为 `@cs:<sid>`），要放行或审核。见接入文档 §10.11（服务端 ≥ v1.21.0） |
| 用户注销账号 | 你方冷静期走完后，**先导出再注销**：`GET /users/{user_id}/export`（资料、会话、黑名单）+ `GET /users/{user_id}/export/messages?cursor=` 翻页取他发的消息（附件链接临时，收到即转存），再 `DELETE /users/{user_id}`。立即执行、不可恢复、幂等；他发的消息保留在对方记录里、发送者显示「已注销用户」；之后该 user_id 导入、签令牌、发消息都回 `IM_USER_NOT_FOUND`，**不能复用**。见接入文档 §4.11（服务端 ≥ v1.23.0） |
| 收用户举报 | IM 设置打开「推送用户举报」后收异步回调 `report` `{report_id, reporter, target, reason, detail, conversation_id, evidence, created_at}`；同一举报人对同一人有待处理单时不再推。`evidence` 里图片等链接是临时地址，收到即转存。处置（如封号）自己调 `PATCH /users/{user_id}`，IM 后台的举报单状态不会跟着变。见接入文档 §8.8 |
| 同步好友关系 | 你方已有好友体系、或从别家迁过来：`PUT /users/{user_id}/friends/{target}`（双向建立，可带 `{"remark"}` 设 user_id 一侧备注）、`POST /friends/batch` `{"pairs":[{"user_id","friend_id"}]}`（1–100 对，任一不合法整批拒绝）、`DELETE /users/{user_id}/friends/{target}?both=true`（默认只删 user_id 一侧）、`GET /users/{user_id}/friends`。不看加好友方式与黑名单；双方须已导入、未注销（注销后重建不了），每人 3000 上限。用户在 App 里加删好友时，打开「推送好友变化」收异步回调 `friend_changed` `{action: added|removed, user_id, friend_id, via: request|server}`，一个方向一条，你自己调接口产生的 `via` 是 `server`。见接入文档 §4.12、§8.9（服务端 ≥ v1.24.0） |
| 代发订单 / 商品卡片 | `POST /messages`，`type: custom`，在 `content.data.im_card` 里带标准卡片外壳（title 必填；fields 放订单号、状态等发送时快照；web_link / app_link / mp_path 分别给网页、App、小程序），客服工作台按它画卡片，见接入文档 §5.9 |

黑名单以接入方为准时：在自家拉黑事务提交后调 IM；IM 调用失败就记一条待重试任务，不要回滚自家拉黑。

## 3. 回调验签

签名 `hex(HMAC-SHA256(回调密钥, X-Im-Timestamp + "\n" + 原始请求体))`。三件事缺一不可：**原始请求体**、**常量时间比较**、**时间戳 5 分钟窗口**。
after_send 按 `X-Im-Delivery-Id` 去重；data 带 `to_muted`（接收方对该会话开了免打扰，为 true 时建议不推离线），`to_unread_total` 不计入免打扰会话；三种回调都带用户来源（before_send / after_send 的 `from_source`、`to_source`，user_state 的 `source`）：`app` 自己的用户、`visitor` 网页访客、`wechat` 公众号 / 小程序客服的用户、`service` 客服，缺省按 `app`；**只给 `to_source` 为 `app` 的推离线**，访客与微信用户的 user_id 不在自家用户表里；before_send 显式回 `allow: true`。

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

响应：before_send 回 `{"code":0,"data":{"allow":true}}` 或 `{"code":0,"data":{"allow":false,"reason":"…"}}`；after_send、message_recalled、user_state、cs_session、report、friend_changed 回 `{"code":0}`；resolve_user 回 `{"code":0,"data":{"user_id":"…"}}`，不认识为空串。
