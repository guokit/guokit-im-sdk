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

    public function testDeleteAndExportUser(): void
    {
        $empty = json_encode(['code' => 0, 'message' => 'ok', 'data' => new \stdClass()]);
        $im = $this->client(new Response(200, [], $empty));
        $this->assertSame([], $im->deleteUser('u 1'));
        $req = $this->history[0]['request'];
        $this->assertSame('DELETE', $req->getMethod());
        $this->assertSame('/api/im/v1/server/users/u%201', $req->getUri()->getPath());

        $page = json_encode(['code' => 0, 'message' => 'ok', 'data' => ['items' => [], 'next_cursor' => '']]);
        $im = $this->client(new Response(200, [], $page));
        $this->assertSame('', $im->exportMessages('u1')['next_cursor']);
        $req = $this->history[0]['request'];
        $this->assertSame('/api/im/v1/server/users/u1/export/messages', $req->getUri()->getPath());
        $this->assertSame('limit=100', $req->getUri()->getQuery());

        $im = $this->client(new Response(200, [], $page));
        $im->exportMessages('u1', '42', 10);
        $this->assertSame('limit=10&cursor=42', $this->history[0]['request']->getUri()->getQuery());
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

    public function testRecallMessage(): void
    {
        $im = $this->client(new Response(200, [], json_encode([
            'code' => 0, 'message' => 'ok',
            'data' => ['id' => 1024, 'type' => 'recalled', 'content' => ['by' => 'server']],
        ])));
        $this->assertSame('recalled', $im->recallMessage(1024)['type']);
        $req = $this->history[0]['request'];
        $this->assertSame('POST', $req->getMethod());
        $this->assertSame('/api/im/v1/server/messages/1024/recall', $req->getUri()->getPath());
    }

    public function testServiceMethods(): void
    {
        $ok = json_encode(['code' => 0, 'message' => 'ok', 'data' => ['service_id' => 'shop_1', 'token' => 'tk']]);
        $cases = [
            [fn(Client $im) => $im->upsertService('shop_1', '甲店'), 'PUT', '/services/shop_1', ['name' => '甲店', 'avatar_url' => '']],
            [fn(Client $im) => $im->upsertService('shop_1', '甲店', '', []), 'PUT', '/services/shop_1', ['name' => '甲店', 'avatar_url' => '', 'settings' => []]],
            [fn(Client $im) => $im->setServiceStatus('shop_1', 0), 'PATCH', '/services/shop_1', ['status' => 0]],
            [fn(Client $im) => $im->serviceSummary('shop_1'), 'GET', '/services/shop_1/summary', null],
            [fn(Client $im) => $im->replaceServiceAgents('shop_1', [3 => ['external_id' => 'e1', 'nickname' => '王']]), 'PUT', '/services/shop_1/agents', ['agents' => [['external_id' => 'e1', 'nickname' => '王']]]],
            [fn(Client $im) => $im->importServices([['service_id' => 'a', 'name' => 'A']]), 'POST', '/services/batch', ['services' => [['service_id' => 'a', 'name' => 'A']]]],
            [fn(Client $im) => $im->upsertServiceAgent('shop_1', 'e@x', '小王', 3), 'PUT', '/services/shop_1/agents/e%40x', ['nickname' => '小王', 'max_concurrent' => 3]],
            [fn(Client $im) => $im->removeServiceAgent('shop_1', 'e1'), 'DELETE', '/services/shop_1/agents/e1', null],
            [fn(Client $im) => $im->issueAgentToken('shop_1', 'e1'), 'POST', '/services/shop_1/agents/e1/token', null],
        ];
        foreach ($cases as [$call, $method, $path, $body]) {
            $im = $this->client(new Response(200, [], $ok));
            $this->assertSame('shop_1', $call($im)['service_id']);
            $req = $this->history[0]['request'];
            $this->assertSame($method, $req->getMethod());
            $this->assertSame('/api/imcs/v1/server' . $path, $req->getUri()->getPath());
            $this->assertSame($body, json_decode((string) $req->getBody(), true));
        }
        foreach (['serviceAgents' => '/agents', 'serviceSessions' => '/sessions'] as $fn => $suffix) {
            $im = $this->client(new Response(200, [], json_encode(['code' => 0, 'message' => 'ok', 'data' => ['items' => [['external_id' => 'e1']]]])));
            $this->assertSame([['external_id' => 'e1']], $im->$fn('shop_1'));
            $this->assertSame('/api/imcs/v1/server/services/shop_1' . $suffix, $this->history[0]['request']->getUri()->getPath());
        }
        $im = $this->client(new Response(200, [], json_encode(['code' => 0, 'message' => 'ok', 'data' => ['items' => [], 'next_cursor' => '']])));
        $this->assertSame('', $im->services('7', 10)['next_cursor']);
        $this->assertSame('cursor=7&limit=10', $this->history[0]['request']->getUri()->getQuery());
        // 空设置要发成 {}，发成 [] 会被服务端拒绝
        $im = $this->client(new Response(200, [], $ok));
        $im->upsertService('shop_1', '甲店', '', []);
        $this->assertStringContainsString('"settings":{}', (string) $this->history[0]['request']->getBody());
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
