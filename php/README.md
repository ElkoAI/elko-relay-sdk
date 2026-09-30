# Relay Telemetry — PHP client

Requires: PHP 8.0+, no extensions required (zlib optional).

## Install
Copy `src/Client.php`, or `composer require` once published (PSR-4 `Relay\\Telemetry\\`).

## Configure
```bash
export RELAY_URL=https://relay.example.com
export RELAY_APP_KEY=rk_your_app_key
export RELAY_TELEM_ENABLED=1     # no-op until set
# optional: RELAY_TELEM_SERVICE, RELAY_TELEM_ENV, RELAY_TELEM_VERSION, RELAY_TELEM_HOST
```

## Hello
```php
$t = \Relay\Telemetry\Client::fromEnv();
$t->counter('orders.placed', 1, ['region' => 'eu']);
$done = $t->timer('db.query_ms'); runQuery(); $done();
$t->log('error', 'checkout failed');  // sent once at shutdown (after the response under php-fpm)
```

Calls never block or raise; events are queued (bounded), batched, gzip'd and POSTed
to `/ingest/v1/batch` with retry/backoff. Counters are **deltas**. Keep tags
low-cardinality ([guide](../docs/tagging-and-cardinality.md)). Wire contract: [SPEC.md](../SPEC.md).

## Try it
```bash
cd php && php example.php   # smoke: php -S 127.0.0.1:18101 tests/mock.php & php tests/smoke.php
```
