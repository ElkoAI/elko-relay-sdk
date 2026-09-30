<?php
// php example.php   (RELAY_URL, RELAY_APP_KEY, RELAY_TELEM_ENABLED=1)
require __DIR__ . '/src/Client.php';

$t = \Relay\Telemetry\Client::fromEnv();
$t->event('demo.started', 'hello from PHP');
for ($i = 0; $i < 20; $i++) {
    $done = $t->timer('demo.work_ms', ['step' => 'compute']);
    usleep((10 + $i * 5) * 1000);
    $done();
    $t->counter('demo.iterations');
    $t->gauge('demo.progress', ($i + 1) / 20 * 100);
}
$t->log('info', 'demo finished');
$t->heartbeat();
$t->close(); // flush on exit (also automatic at shutdown)
echo "sent={$t->sent} dropped={$t->dropped}\n";
