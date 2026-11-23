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
