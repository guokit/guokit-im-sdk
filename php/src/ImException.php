<?php

declare(strict_types=1);

namespace Guokit\Im;

/**
 * IM 调用失败：业务错误（getErrorCode 为服务端错误码）、网络错误（NETWORK）、
 * 响应异常（INTERNAL）、回调验签失败（CALLBACK_INVALID）。
 */
class ImException extends \RuntimeException
{
    private string $errorCode;
    private int $httpStatus;

    public function __construct(string $errorCode, string $message, int $httpStatus = 0, ?\Throwable $previous = null)
    {
        parent::__construct($message, 0, $previous);
        $this->errorCode = $errorCode;
        $this->httpStatus = $httpStatus;
    }

    public function getErrorCode(): string
    {
        return $this->errorCode;
    }

    public function getHttpStatus(): int
    {
        return $this->httpStatus;
    }
}
