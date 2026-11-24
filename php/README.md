# guokit/im（PHP SDK）

果壳 IM 服务端 PHP SDK：导入用户、签令牌、封禁、黑名单、代发消息、回调验签。PHP >= 8.0，依赖 Guzzle 7，不依赖框架。

## 安装

仓库尚未发布到 Packagist，用 VCS 方式引入。在你项目的 `composer.json` 里加：

```json
{
  "repositories": [
    { "type": "vcs", "url": "https://github.com/guokit/guokit-im-sdk" }
  ],
  "require": {
    "guokit/im": "^0.6"
  }
}
```

然后 `composer update guokit/im`。

## 快速上手

```php
use Guokit\Im\Client;
use Guokit\Im\ImException;

$im = new Client('https://im.example.com', getenv('IM_API_KEY'), ['timeout' => 5]);

try {
    $im->upsertUser('u1001', '张三', 'https://cdn.example.com/a.png'); // 签令牌前必须先导入
    $r = $im->issueToken('u1001');   // ['token' => '…', 'expires_at' => '2026-11-27 10:00:00']
} catch (ImException $e) {
    // $e->getErrorCode() 如 IM_USER_NOT_FOUND / NETWORK / INTERNAL；$e->getHttpStatus() 为 HTTP 状态码
}
```

## API 一览

每个方法返回响应包里的 `data`（数组）；业务失败（`code` 不是整数 0）、网络错误、响应不是 JSON 都抛 `ImException`。

| 方法 | 说明 |
|---|---|
| `ping()` | 连通与 Key 自检，返回 `app_id`、`name` |
| `upsertUser($userId, $nickname = '', $avatarUrl = '')` | 导入或更新单个用户（传空串即清空） |
| `importUsers(array $users)` | 批量导入，1–100 个，任一项不合法整批拒绝 |
| `issueToken($userId)` | 签令牌，返回 `token` 与 `expires_at` |
| `setUserStatus($userId, int $status)` | `0` 封禁、`1` 解封 |
| `kick($userId)` | 踢下线，旧令牌全部作废 |
| `block($userId, $target)` / `unblock($userId, $target)` | 拉黑 / 解除（`$userId` 拒收 `$target` 的消息） |
| `blocks($userId, $offset = 0, $limit = 50)` | 黑名单列表，返回 `items` 与 `has_more` |
| `conversationSettings($userId, $peerId)` | 按「用户 + 对方」查会话设置（对方 `@cs` 即客服会话）；查不到抛 `VALIDATION`（HTTP 404） |
| `setConversationSettings($userId, $peerId, array $settings)` | 置顶 / 免打扰：`['pinned'=>bool, 'muted'=>bool]`，至少一个 |
| `clearConversation($userId, $peerId)` | 清空该用户这一侧的聊天记录 |
| `deleteConversation($userId, $peerId)` | 删除会话（清空 + 移出列表 + 取消置顶，免打扰保留） |
| `sendMessage($from, $to, $type, array $content, $clientMsgId)` | 以某用户身份代发；图片请用外链 `url` 形式 |
| `history($conversationId, $afterSeq = null, $beforeSeq = null, $limit = 30)` | 查会话历史（审计） |
| `onlineStatus(array $userIds)` | 批量查询在线状态（1–100 个），返回 `[user_id => bool]` |

`user_id`、`target` 进路径前已自动 `rawurlencode`。`ImException` 的 `getErrorCode()` 在非业务错误时取值：`NETWORK`（网络异常）、`INTERNAL`（响应不是合法 JSON）、`CALLBACK_INVALID`（回调验签失败）。

## 回调验签

必须用**原始请求体**验签，不要先 `json_decode` 再编码。时间戳须为数字且与当前相差不超过 300 秒（第 5 个参数可改）。

`Callback::verify` 通过后返回 `CallbackEvent`：`$event->name`（`before_send` / `after_send` / `user_state` / `resolve_user`，不认识的事件也请回 `Callback::ack()`）与 `$event->data`（数组）。去重用的 `X-Im-Delivery-Id` 请自行从请求头取。

响应体用 `Callback::allow()`、`Callback::reject('原因')`、`Callback::ack()` 生成（均返回 JSON 字符串）。

### 原生 PHP

```php
use Guokit\Im\Callback;
use Guokit\Im\ImException;

try {
    $event = Callback::verify(
        file_get_contents('php://input'),
        $_SERVER['HTTP_X_IM_TIMESTAMP'] ?? null,
        $_SERVER['HTTP_X_IM_SIGNATURE'] ?? null,
        getenv('IM_CALLBACK_SECRET')
    );
} catch (ImException $e) {
    http_response_code(401);
    exit;
}
header('Content-Type: application/json');
if ($event->name === 'before_send') {
    echo containsBannedWords($event->data) ? Callback::reject('含违规内容') : Callback::allow();
} elseif ($event->name === 'resolve_user') {
    // 微信用户是哪个会员：按 openid / unionid 查自己的绑定表，3 秒内回。只返回已确认绑定、且已导入 IM 的会员；
    // 不认识回空串（站点会清掉已有关联），查询出错请回 code 非 0（站点保留原结果稍后再问）
    $d = $event->data;   // channel、account_type（oa / mp）、appid、openid、unionid（可能为空串）
    echo json_encode(['code' => 0, 'data' => ['user_id' => findMemberByWechat($d['appid'], $d['openid'], $d['unionid']) ?? '']]);
} else {
    // after_send：先按 X-Im-Delivery-Id 落库去重，再处理
    // 只给自己的用户推离线：to_source 为 visitor 的是网页访客、wechat 是微信用户（都没有设备）、service 是平台客服；
    // 旧版服务端没有该字段，所以 @cs 仍单独排除。to_muted 为 true 表示接收方开了免打扰
    $d = $event->data;
    if (($d['to_source'] ?? 'app') === 'app' && $d['to'] !== '@cs'
        && ($d['to_online'] ?? null) === false && !($d['to_muted'] ?? false)) {
        // pushOffline(...)；$d['message']['sender_role'] === 'bot' 的内容由 AI 生成
    }
    echo Callback::ack();
}
```

### ThinkPHP 8

```php
$event = Callback::verify(
    $request->getContent(),
    $request->header('x-im-timestamp'),
    $request->header('x-im-signature'),
    env('IM_CALLBACK_SECRET')
);
$deliveryId = $request->header('x-im-delivery-id');
return response(Callback::ack(), 200, ['Content-Type' => 'application/json']);
```

### Laravel

```php
$event = Callback::verify(
    $request->getContent(),
    $request->header('X-Im-Timestamp'),
    $request->header('X-Im-Signature'),
    config('services.im.callback_secret')
);
return response(Callback::ack(), 200)->header('Content-Type', 'application/json');
```

验签失败请回 401，并把 `ImException` 捕获掉，不要让框架当成 500。

## 迁移与常见问题

- **签令牌前先 `upsertUser`**，否则 `IM_USER_NOT_FOUND`。登录时同步资料再签令牌即可。
- `avatar_url` 必须是 http(s) 绝对地址或空串，相对路径要先补全域名。
- `expires_at` 是东八区的 `Y-m-d H:i:s` 字符串，原样透传给客户端，以它判断何时续签。
- 令牌每次签发都是新的，旧令牌到期前仍有效；要让旧令牌全部作废用 `kick`。

## 测试

```bash
composer install
vendor/bin/phpunit -c php/phpunit.xml
```
