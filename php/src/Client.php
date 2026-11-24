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

    /** 按「用户 + 对方」查会话设置；对方为 `@cs` 即客服会话。查不到抛 VALIDATION（HTTP 404）。 */
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

    private function convPath(string $userId, string $peerId): string
    {
        return '/users/' . rawurlencode($userId) . '/conversations/' . rawurlencode($peerId);
    }

    private function blockPath(string $userId, string $target): string
    {
        return '/users/' . rawurlencode($userId) . '/blocks/' . rawurlencode($target);
    }

    private function call(string $method, string $path, array $opt = []): array
    {
        try {
            $res = $this->http->request($method, self::PREFIX . $path, $opt);
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
