<?php
// 本机冒烟：IM_BASE_URL=http://127.0.0.1:8080 IM_API_KEY=imk_xxx php php/smoke.php
require __DIR__ . '/../vendor/autoload.php';

use Guokit\Im\Client;

$im = new Client(getenv('IM_BASE_URL') ?: 'http://127.0.0.1:8080', getenv('IM_API_KEY') ?: '');
$show = static function (string $step, $r): void {
    echo $step, ': ', json_encode($r, JSON_UNESCAPED_UNICODE), "\n";
};

$a = 'smoke_' . bin2hex(random_bytes(4));
$b = 'smoke_' . bin2hex(random_bytes(4));

$show('ping', $im->ping());
$show('upsertUser a', $im->upsertUser($a, '冒烟甲'));
$show('upsertUser b', $im->upsertUser($b, '冒烟乙'));
$show('issueToken a', $im->issueToken($a));
$msg = $im->sendMessage($a, $b, 'text', ['text' => 'hello from php sdk'], bin2hex(random_bytes(8)));
$show('sendMessage', $msg);
$show('history', $im->history((int) $msg['conversation_id']));
$show('block', $im->block($b, $a));
$show('blocks', $im->blocks($b));
$show('unblock', $im->unblock($b, $a));
echo "OK\n";
