<?php
declare(strict_types=1);

namespace Relay\Telemetry;

/**
 * Elko Relay telemetry client — PHP 8.0+, no dependencies (streams + optional zlib).
 *
 *   $t = \Relay\Telemetry\Client::fromEnv();   // RELAY_URL, RELAY_APP_KEY, RELAY_TELEM_ENABLED=1
 *   $t->counter('orders.placed', 1, ['region' => 'eu']);
 *   $t->gauge('queue.depth', 42);
 *   $done = $t->timer('db.query_ms'); $done();   // records elapsed ms
 *   $t->log('error', 'checkout failed');
 *   // flushes automatically at request/CLI shutdown (register_shutdown_function)
 *
 * PHP has no background threads, so events queue in memory and are sent as ONE
 * batch at shutdown (or every $flushAt events). With php-fpm the flush runs
 * after the response is sent (fastcgi_finish_request) so it never delays users.
 */
final class Client
{
    /** @var array<int,array<string,mixed>> */
    private array $q = [];
    public int $dropped = 0;
    public int $sent = 0;
    private bool $closed = false;

    public function __construct(
        private string $url = '',
        private string $appKey = '',
        private bool $enabled = false,
        private string $host = '',
        private string $service = '',
        private string $env = '',
        private string $version = '',
        private int $maxQueue = 10000,
        private int $flushAt = 500,
        private int $retries = 3,
        private float $timeout = 3.0,
        private ?\Closure $onError = null,
    ) {
        $this->url = rtrim($this->url, '/');
        if ($this->host === '') {
            $this->host = gethostname() ?: 'php';
        }
        if ($this->active()) {
            register_shutdown_function(function (): void {
                if (function_exists('fastcgi_finish_request')) {
                    @fastcgi_finish_request();
                }
                $this->close();
            });
        }
    }

    public static function fromEnv(): self
    {
        $t = static fn (string $v): bool => in_array(strtolower(trim($v)), ['1', 'true', 'yes', 'on'], true);
        return new self(
            (string) getenv('RELAY_URL'), (string) getenv('RELAY_APP_KEY'),
            $t((string) getenv('RELAY_TELEM_ENABLED')), (string) getenv('RELAY_TELEM_HOST'),
            (string) getenv('RELAY_TELEM_SERVICE'), (string) getenv('RELAY_TELEM_ENV'),
            (string) getenv('RELAY_TELEM_VERSION'),
        );
    }

    private function active(): bool
    {
        return $this->enabled && $this->url !== '' && $this->appKey !== '';
    }

    /** @param array<string,mixed> $e */
    private function push(array $e, ?array $tags): void
    {
        if (!$this->active() || $this->closed) {
            return;
        }
        if ($tags) {
            $e['tags'] = $tags;
        }
        $e['ts'] = gmdate('Y-m-d\TH:i:s\Z');
        if (count($this->q) >= $this->maxQueue) {
            array_shift($this->q);
            $this->dropped++;
        }
        $this->q[] = $e;
        if (count($this->q) >= $this->flushAt) {
            $this->flush();
        }
    }

    public function counter(string $name, float $delta = 1, ?array $tags = null): void
    {
        $this->push(['kind' => 'metric', 'type' => 'counter', 'name' => $name, 'value' => $delta], $tags);
    }

    public function gauge(string $name, float $value, ?array $tags = null): void
    {
        $this->push(['kind' => 'metric', 'type' => 'gauge', 'name' => $name, 'value' => $value], $tags);
    }

    public function histogram(string $name, float $value, string $unit = '', ?array $tags = null): void
    {
        $this->push(['kind' => 'metric', 'type' => 'histogram', 'name' => $name, 'value' => $value, 'unit' => $unit], $tags);
    }

    /** Returns a closure; call it to record the elapsed milliseconds. */
    public function timer(string $name, ?array $tags = null): \Closure
    {
        $t0 = hrtime(true);
        return function () use ($name, $tags, $t0): void {
            $this->histogram($name, (hrtime(true) - $t0) / 1e6, 'ms', $tags);
        };
    }

    public function log(string $level, string $msg, ?array $tags = null): void
    {
        $this->push(['kind' => 'log', 'level' => $level, 'msg' => $msg], $tags);
    }

    public function event(string $name, string $msg = '', ?array $tags = null): void
    {
        $this->push(['kind' => 'event', 'name' => $name, 'msg' => $msg], $tags);
    }

    public function span(string $name, string $traceId, string $spanId, float $ms, bool $failed = false, string $parentId = '', ?array $tags = null): void
    {
        $e = ['kind' => 'span', 'name' => $name, 'value' => $ms, 'unit' => 'ms', 'trace_id' => $traceId,
            'span_id' => $spanId, 'status' => $failed ? 'error' : 'ok'];
        if ($parentId !== '') {
            $e['parent_id'] = $parentId;
        }
        $this->push($e, $tags);
    }

    public function heartbeat(): void
    {
        $this->push(['kind' => 'hb'], null);
    }

    public function flush(): void
    {
        if (!$this->active()) {
            return;
        }
        while ($this->q) {
            $batch = array_splice($this->q, 0, 1000);
            if ($this->post($batch)) {
                $this->sent += count($batch);
            } else {
                $this->dropped += count($batch);
            }
        }
    }

    public function close(): void
    {
        if ($this->closed) {
            return;
        }
        $this->flush();
        $this->closed = true;
    }

    /** @param array<int,array<string,mixed>> $batch */
    private function post(array $batch): bool
    {
        $res = array_filter(['service' => $this->service, 'env' => $this->env, 'version' => $this->version, 'host' => $this->host]);
        $body = json_encode(['resource' => (object) $res, 'events' => $batch], JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
        $headers = ['Authorization: Bearer ' . $this->appKey, 'Content-Type: application/json'];
        if (function_exists('gzencode')) {
            $body = gzencode($body);
            $headers[] = 'Content-Encoding: gzip';
        }
        $delay = 0.3;
        for ($attempt = 0; $attempt <= $this->retries; $attempt++) {
            $wait = $delay;
            $ctx = stream_context_create(['http' => [
                'method' => 'POST', 'header' => implode("\r\n", $headers), 'content' => $body,
                'timeout' => $this->timeout, 'ignore_errors' => true,
            ]]);
            $out = @file_get_contents($this->url . '/ingest/v1/batch', false, $ctx);
            $code = 0;
            $retryAfter = 0;
            foreach ($http_response_header ?? [] as $h) {
                if (preg_match('#^HTTP/\S+\s+(\d{3})#', $h, $m)) {
                    $code = (int) $m[1];
                } elseif (stripos($h, 'Retry-After:') === 0) {
                    $retryAfter = (int) trim(substr($h, 12));
                }
            }
            if ($out !== false && ($code === 202 || $code === 200)) {
                return true;
            }
            if ($code >= 400 && $code < 500 && $code !== 429) {
                if ($this->onError) {
                    ($this->onError)(new \RuntimeException("relay telemetry: hub returned HTTP $code"));
                }
                return false; // retrying cannot help
            }
            if ($retryAfter > 0) {
                $wait = (float) $retryAfter;
            }
            if ($attempt < $this->retries) {
                usleep((int) (($wait + mt_rand() / mt_getrandmax() * $wait * 0.5) * 1e6));
                $delay = min($delay * 2, 10.0);
            }
        }
        return false;
    }
}
