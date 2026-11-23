<?php

declare(strict_types=1);

namespace Guokit\Im;

/** 验签通过后的回调事件：name 为 before_send / after_send / user_state，data 为事件数据。 */
class CallbackEvent
{
    public string $name;
    public array $data;

    public function __construct(string $name, array $data)
    {
        $this->name = $name;
        $this->data = $data;
    }
}
