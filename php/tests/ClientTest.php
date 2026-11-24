<?php

declare(strict_types=1);

namespace Guokit\Im\Tests;

use GuzzleHttp\Handler\MockHandler;
use GuzzleHttp\HandlerStack;
use GuzzleHttp\Middleware;
use GuzzleHttp\Psr7\Response;
use Guokit\Im\Client;
use Guokit\Im\ImException;
use PHPUnit\Framework\TestCase;

class ClientTest extends TestCase
{
    private array $history = [];

    private function client(Response $res): Client
    {
        $this->history = [];
        $stack = HandlerStack::create(new MockHandler([$res]));
        $stack->push(Middleware::history($this->history));
        return new Client('https://im.example.com', 'imk_test', ['handler' => $stack]);
    }

    public function testOnlineStatus(): void
    {
        $im = $this->client(new Response(200, [], json_encode([
            'code' => 0, 'message' => 'ok',
            'data' => ['items' => [['user_id' => 'u1', 'online' => true], ['user_id' => 'u2', 'online' => false]]],
        ])));
        $this->assertSame(['u1' => true, 'u2' => false], $im->onlineStatus(['u1', 'u2']));
        $req = $this->history[0]['request'];
        $this->assertSame('POST', $req->getMethod());
        $this->assertSame('/api/im/v1/server/users/online', $req->getUri()->getPath());
        $this->assertSame(['user_ids' => ['u1', 'u2']], json_decode((string) $req->getBody(), true));
    }

    public function testConversationSettingsMethods(): void
    {
        $data = ['conversation_id' => 7, 'peer_user_id' => '@cs', 'pinned' => true, 'pinned_at' => null,
            'muted' => false, 'clear_seq' => 0, 'unread' => 0, 'visible' => true];
        $ok = json_encode(['code' => 0, 'message' => 'ok', 'data' => $data]);

        $im = $this->client(new Response(200, [], $ok));
        $this->assertSame(7, $im->conversationSettings('u 1', '@cs')['conversation_id']);
        $req = $this->history[0]['request'];
        $this->assertSame('GET', $req->getMethod());
        $this->assertSame('/api/im/v1/server/users/u%201/conversations/%40cs', $req->getUri()->getPath());

        $im = $this->client(new Response(200, [], $ok));
        $this->assertTrue($im->setConversationSettings('u1', 'u2', ['pinned' => true])['pinned']);
        $req = $this->history[0]['request'];
        $this->assertSame('PUT', $req->getMethod());
        $this->assertSame('/api/im/v1/server/users/u1/conversations/u2/settings', $req->getUri()->getPath());
        $this->assertSame(['pinned' => true], json_decode((string) $req->getBody(), true));

        $im = $this->client(new Response(200, [], $ok));
        $im->clearConversation('u1', '@cs');
        $req = $this->history[0]['request'];
        $this->assertSame('POST', $req->getMethod());
        $this->assertSame('/api/im/v1/server/users/u1/conversations/%40cs/clear', $req->getUri()->getPath());

        $im = $this->client(new Response(200, [], $ok));
        $im->deleteConversation('u1', 'u2');
        $req = $this->history[0]['request'];
        $this->assertSame('DELETE', $req->getMethod());
        $this->assertSame('/api/im/v1/server/users/u1/conversations/u2', $req->getUri()->getPath());
    }

    public function testIssueTokenOk(): void
    {
        $im = $this->client(new Response(200, [], json_encode([
            'code' => 0, 'message' => 'ok',
            'data' => ['token' => 'tk', 'expires_at' => '2026-11-27 10:00:00'],
        ])));
        $r = $im->issueToken('u 1');
        $this->assertSame('tk', $r['token']);
        $req = $this->history[0]['request'];
        $this->assertSame('POST', $req->getMethod());
        $this->assertSame('/api/im/v1/server/users/u%201/token', $req->getUri()->getPath());
        $this->assertSame('imk_test', $req->getHeaderLine('X-Api-Key'));
    }

    public function testBusinessErrorThrows(): void
    {
        $im = $this->client(new Response(200, [], json_encode(['code' => 'IM_USER_NOT_FOUND', 'message' => '用户不存在'])));
        try {
            $im->issueToken('nobody');
            $this->fail('应抛出 ImException');
        } catch (ImException $e) {
            $this->assertSame('IM_USER_NOT_FOUND', $e->getErrorCode());
            $this->assertSame(200, $e->getHttpStatus());
        }
    }
}
