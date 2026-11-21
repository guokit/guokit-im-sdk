<?php

declare(strict_types=1);

namespace Guokit\Im;

/** 回调验签与响应体构造。必须用原始请求体验签，不要先 json_decode 再编码。 */
class Callback
{
    public static function verify(string $rawBody, ?string $timestamp, ?string $signature, string $secret, int $window = 300): CallbackEvent
    {
        if ($timestamp === null || $timestamp === '' || !ctype_digit($timestamp)) {
            throw new ImException('CALLBACK_INVALID', '回调时间戳缺失或不是数字');
        }
        if (abs(time() - (int) $timestamp) > $window) {
            throw new ImException('CALLBACK_INVALID', '回调时间戳已过期');
        }
        $expect = hash_hmac('sha256', $timestamp . "\n" . $rawBody, $secret);
        if (!hash_equals($expect, (string) $signature)) {
            throw new ImException('CALLBACK_INVALID', '回调签名不匹配');
        }
        $payload = json_decode($rawBody, true);
        if (!is_array($payload) || !isset($payload['event']) || !is_string($payload['event'])) {
            throw new ImException('CALLBACK_INVALID', '回调请求体不是合法的事件 JSON');
        }
        $data = isset($payload['data']) && is_array($payload['data']) ? $payload['data'] : [];
        return new CallbackEvent($payload['event'], $data);
    }

    public static function allow(): string
    {
        return self::json(['code' => 0, 'data' => ['allow' => true]]);
    }

    public static function reject(string $reason): string
    {
        return self::json(['code' => 0, 'data' => ['allow' => false, 'reason' => $reason]]);
    }

    public static function ack(): string
    {
        return self::json(['code' => 0]);
    }

    private static function json(array $v): string
    {
        return json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }
}
