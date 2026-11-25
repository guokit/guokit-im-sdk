<?php

declare(strict_types=1);

namespace Guokit\Im;

use GuzzleHttp\Client as Http;
use GuzzleHttp\Exception\GuzzleException;

/** IM 服务端接口客户端。每个方法返回响应包里的 data（数组），失败抛 ImException。 */
class Client
{
    // 不以 / 开头：配合 base_uri 末尾的 /，baseUrl 带子路径（如 https://x.com/im）时不会被 Guzzle 丢掉。
    private const PREFIX = 'api/im/v1/server';
    private const CS_PREFIX = 'api/imcs/v1/server';

    private Http $http;

    /**
     * @param array $options timeout（秒，默认 5）、handler（测试注入 Guzzle HandlerStack）
     */
    public function __construct(string $baseUrl, string $apiKey, array $options = [])
    {
        $cfg = [
            'base_uri' => rtrim($baseUrl, '/') . '/',
            'timeout' => $options['timeout'] ?? 5,
            'http_errors' => false,
            'headers' => [
                'X-Api-Key' => $apiKey,
                'Content-Type' => 'application/json',
            ],
        ];
        if (isset($options['handler'])) {
            $cfg['handler'] = $options['handler'];
        }
        $this->http = new Http($cfg);
    }

    public function ping(): array
    {
        return $this->call('GET', '/ping');
    }

    public function upsertUser(string $userId, string $nickname = '', string $avatarUrl = ''): array
    {
        return $this->call('PUT', '/users/' . rawurlencode($userId), [
            'json' => ['nickname' => $nickname, 'avatar_url' => $avatarUrl],
        ]);
    }

    /** @param array $users 1–100 个 ['user_id'=>…, 'nickname'=>…, 'avatar_url'=>…] */
    public function importUsers(array $users): array
    {
        return $this->call('POST', '/users/batch', ['json' => ['users' => array_values($users)]]);
    }

    /**
     * 批量查询在线状态（1–100 个）。返回 [user_id => bool]，按请求顺序、重复的 id 只出现一次。
     * 不存在、被封禁的用户为 false。这是在线状态的权威来源，user_state 回调只是提醒。
     *
     * @param string[] $userIds
     * @return array<string, bool>
     */
    public function onlineStatus(array $userIds): array
    {
        $data = $this->call('POST', '/users/online', ['json' => ['user_ids' => array_values($userIds)]]);
        $out = [];
        foreach ($data['items'] ?? [] as $item) {
            $out[(string) $item['user_id']] = (bool) $item['online'];
        }
        return $out;
    }

    public function issueToken(string $userId): array
    {
        return $this->call('POST', '/users/' . rawurlencode($userId) . '/token');
    }

    /** 0 封禁，1 正常 */
    public function setUserStatus(string $userId, int $status): array
    {
        return $this->call('PATCH', '/users/' . rawurlencode($userId), ['json' => ['status' => $status]]);
    }

    public function kick(string $userId): array
    {
        return $this->call('POST', '/users/' . rawurlencode($userId) . '/kick');
    }

    public function block(string $userId, string $target): array
    {
        return $this->call('PUT', $this->blockPath($userId, $target));
    }

    public function unblock(string $userId, string $target): array
    {
        return $this->call('DELETE', $this->blockPath($userId, $target));
    }

    public function blocks(string $userId, int $offset = 0, int $limit = 50): array
    {
        return $this->call('GET', '/users/' . rawurlencode($userId) . '/blocks', [
            'query' => ['offset' => $offset, 'limit' => $limit],
        ]);
    }

    /** 按「用户 + 对方」查会话设置；对方为 `@cs` 或 `@cs:<主体标识>` 即客服会话。查不到抛 VALIDATION（HTTP 404）。 */
    public function conversationSettings(string $userId, string $peerId): array
    {
        return $this->call('GET', $this->convPath($userId, $peerId));
    }

    /** @param array $settings ['pinned'=>bool, 'muted'=>bool]，至少一个 */
    public function setConversationSettings(string $userId, string $peerId, array $settings): array
    {
        return $this->call('PUT', $this->convPath($userId, $peerId) . '/settings', ['json' => (object) $settings]);
    }

    /** 清空该用户这一侧的聊天记录 */
    public function clearConversation(string $userId, string $peerId): array
    {
        return $this->call('POST', $this->convPath($userId, $peerId) . '/clear');
    }

    /** 删除会话：清空 + 从列表移除 + 取消置顶，免打扰保留 */
    public function deleteConversation(string $userId, string $peerId): array
    {
        return $this->call('DELETE', $this->convPath($userId, $peerId));
    }

    /** 撤回消息：不限时、不看站点开关，用于处理违规内容。不存在抛 VALIDATION（HTTP 404）。 */
    public function recallMessage(int $messageId): array
    {
        return $this->call('POST', '/messages/' . $messageId . '/recall');
    }

    public function sendMessage(string $from, string $to, string $type, array $content, string $clientMsgId): array
    {
        return $this->call('POST', '/messages', ['json' => [
            'from' => $from,
            'to' => $to,
            'type' => $type,
            'content' => (object) $content,
            'client_msg_id' => $clientMsgId,
        ]]);
    }

    public function history(int $conversationId, ?int $afterSeq = null, ?int $beforeSeq = null, int $limit = 30): array
    {
        $query = ['limit' => $limit];
        if ($afterSeq !== null) {
            $query['after_seq'] = $afterSeq;
        }
        if ($beforeSeq !== null) {
            $query['before_seq'] = $beforeSeq;
        }
        return $this->call('GET', '/conversations/' . $conversationId . '/messages', ['query' => $query]);
    }

    /**
     * 建或改一个客服主体，返回 service_id 与 user_id（用户给它发消息用的 `@cs:<主体标识>`）。
     *
     * @param array|null $settings welcome_text / queue_text / offline_text / timeout_minutes / rating_enabled / visitor_enabled，
     *                             没给的用站点设置；传 null 不改已有设置，传数组整个替换
     */
    public function upsertService(string $serviceId, string $name, string $avatarUrl = '', ?array $settings = null): array
    {
        $body = ['name' => $name, 'avatar_url' => $avatarUrl];
        if ($settings !== null) {
            $body['settings'] = (object) $settings;
        }
        return $this->call('PUT', $this->servicePath($serviceId), ['json' => $body], self::CS_PREFIX);
    }

    /** 1 启用，0 停用（用户发不进来，未结束的接待结束，坐席令牌失效） */
    public function setServiceStatus(string $serviceId, int $status): array
    {
        return $this->call('PATCH', $this->servicePath($serviceId), ['json' => ['status' => $status]], self::CS_PREFIX);
    }

    /** 主体资料、坐席数、在线坐席数与排队数 */
    public function serviceSummary(string $serviceId): array
    {
        return $this->call('GET', $this->servicePath($serviceId) . '/summary', [], self::CS_PREFIX);
    }

    /**
     * 批量导入主体与坐席，首次接入用：最多 100 个主体、合计 500 个坐席。遇错即停，可整批重试。
     *
     * @param array $services ['service_id'=>…, 'name'=>…, 'avatar_url'=>…, 'settings'=>[…], 'agents'=>[['external_id'=>…, 'nickname'=>…], …]]
     */
    public function importServices(array $services): array
    {
        foreach ($services as &$s) {
            if (isset($s['settings'])) {
                $s['settings'] = (object) $s['settings'];
            }
        }
        return $this->call('POST', '/services/batch', ['json' => ['services' => array_values($services)]], self::CS_PREFIX);
    }

    /** 建或改一名坐席（你方员工）；移除过的重新启用。 */
    public function upsertServiceAgent(string $serviceId, string $externalId, string $nickname, string $avatarUrl = '', ?int $maxConcurrent = null): array
    {
        $body = ['nickname' => $nickname, 'avatar_url' => $avatarUrl];
        if ($maxConcurrent !== null) {
            $body['max_concurrent'] = $maxConcurrent;
        }
        return $this->call('PUT', $this->agentPath($serviceId, $externalId), ['json' => $body], self::CS_PREFIX);
    }

    /** 移除坐席：令牌失效、断开，接待中的转回排队。 */
    public function removeServiceAgent(string $serviceId, string $externalId): array
    {
        return $this->call('DELETE', $this->agentPath($serviceId, $externalId), [], self::CS_PREFIX);
    }

    /** 签坐席令牌（2 小时，工作台页面自动续期），返回 token 与 expires_at。签之前请自己确认该员工有权限。 */
    public function issueAgentToken(string $serviceId, string $externalId): array
    {
        return $this->call('POST', $this->agentPath($serviceId, $externalId) . '/token', [], self::CS_PREFIX);
    }

    private function servicePath(string $serviceId): string
    {
        return '/services/' . rawurlencode($serviceId);
    }

    private function agentPath(string $serviceId, string $externalId): string
    {
        return $this->servicePath($serviceId) . '/agents/' . rawurlencode($externalId);
    }

    private function convPath(string $userId, string $peerId): string
    {
        return '/users/' . rawurlencode($userId) . '/conversations/' . rawurlencode($peerId);
    }

    private function blockPath(string $userId, string $target): string
    {
        return '/users/' . rawurlencode($userId) . '/blocks/' . rawurlencode($target);
    }

    private function call(string $method, string $path, array $opt = [], string $prefix = self::PREFIX): array
    {
        try {
            $res = $this->http->request($method, $prefix . $path, $opt);
        } catch (GuzzleException $e) {
            throw new ImException('NETWORK', $e->getMessage(), 0, $e);
        }
        $status = $res->getStatusCode();
        $body = json_decode((string) $res->getBody(), true);
        if (!is_array($body) || !array_key_exists('code', $body)) {
            throw new ImException('INTERNAL', '响应不是合法的 JSON 响应包（HTTP ' . $status . '）', $status);
        }
        if ($body['code'] !== 0) {
            throw new ImException((string) $body['code'], (string) ($body['message'] ?? ''), $status);
        }
        return is_array($body['data'] ?? null) ? $body['data'] : [];
    }
}
