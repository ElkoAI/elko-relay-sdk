<?php
// php -S 127.0.0.1:18101 tests/mock.php & php tests/smoke.php
require __DIR__ . '/../src/Client.php';
$c = new \Relay\Telemetry\Client('http://127.0.0.1:18101', 'rk_t', true, flushAt: 100000);
for ($i = 0; $i < 300; $i++) { $c->counter('n', 1, ['a' => 'b']); }
$done = $c->timer('t'); $done();
$c->close();
if ($c->sent !== 301 || $c->dropped !== 0) { fwrite(STDERR, "FAIL sent={$c->sent} dropped={$c->dropped}\n"); exit(1); }
$bad = new \Relay\Telemetry\Client('http://127.0.0.1:18101/bad', 'rk_wrong', true);
$bad->gauge('g', 1); $bad->close();
if ($bad->dropped !== 1) { fwrite(STDERR, "FAIL 401 should drop, dropped={$bad->dropped}\n"); exit(1); }
echo "php ok\n";
