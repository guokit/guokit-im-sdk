<?php

declare(strict_types=1);

namespace Guokit\Im\Tests;

use Guokit\Im\Callback;
use Guokit\Im\ImException;
use PHPUnit\Framework\TestCase;

class CallbackTest extends TestCase
{
    private const SECRET = 's3cret';
    private const BODY = '{"event":"before_send","data":{"from":"u1","to":"u2"}}';

    private function sign(string $ts, string $body): string
    {
        return hash_hmac('sha256', $ts . "\n" . $body, self::SECRET);
    }

    public function testVerifyOk(): void
    {
        $ts = (string) time();
        $e = Callback::verify(self::BODY, $ts, $this->sign($ts, self::BODY), self::SECRET);
        $this->assertSame('before_send', $e->name);
        $this->assertSame('u1', $e->data['from']);
        $this->assertSame('{"code":0,"data":{"allow":false,"reason":"含违规"}}', Callback::reject('含违规'));
    }

    public function testTamperedBodyFails(): void
    {
        $ts = (string) time();
        $this->expectException(ImException::class);
        Callback::verify(self::BODY . ' ', $ts, $this->sign($ts, self::BODY), self::SECRET);
    }

    public function testExpiredTimestampFails(): void
    {
        $ts = (string) (time() - 1000);
        try {
            Callback::verify(self::BODY, $ts, $this->sign($ts, self::BODY), self::SECRET);
            $this->fail('应抛出 ImException');
        } catch (ImException $e) {
            $this->assertSame('CALLBACK_INVALID', $e->getErrorCode());
        }
    }
}
