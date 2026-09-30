# Relay Telemetry — wire contract (v1)

Status: BETA. Host placeholder: `https://relay.example.com`.

## 1. Auth

Every ingest request carries an **app key**:

```
Authorization: Bearer rk_…
```

The app key determines the tenant and app. **Clients never choose routing**: any
org/app/subject fields in a body are ignored. Bad/revoked/disabled key → `401`.
Browsers must not hold app keys; send from a server.

## 2. Endpoints

All `POST`, all under `/ingest/v1/`. Bodies may be `Content-Encoding: gzip`.

| Path | Body | Semantics |
|------|------|-----------|
| `/ingest/v1/log`    | object, array, NDJSON, or `text/plain` lines | atomic |
| `/ingest/v1/metric` | object, array, NDJSON | atomic |
| `/ingest/v1/event`  | object, array, NDJSON | atomic |
| `/ingest/v1/span`   | object, array, NDJSON | atomic |
| `/ingest/v1/hb`     | `{}` or an event | atomic |
| `/ingest/v1/batch`  | array, NDJSON, or `{"resource":{…},"events":[…]}`; each item has its own `kind` | **partial accept** |
| `/ingest/v1/statsd` | DogStatsD lines (`name:1\|c\|#k:v`) | partial accept |
| `/ingest/v1/otlp/metrics` `/logs` `/traces` | OTLP/HTTP **JSON** (`Content-Type: application/json`); protobuf → `415` | partial accept |

*Atomic*: one invalid item rejects the whole request (`400`). *Partial accept*:
valid items are stored, the response lists `errors` for the rest.

`text/plain` to `/log`: one log line per line; query params `?name=&level=&host=`.

## 3. Envelope

One JSON object per event. Only `kind` (implied by the path on single-kind
endpoints) is required; everything else defaults.

| Field | Type | Notes |
|-------|------|-------|
| `v` | int | schema version, default `1` |
| `kind` | string | `log` \| `metric` \| `event` \| `span` \| `hb` |
| `ts` | RFC 3339 string | default: server receive time. Older than 24 h → rejected; >5 min in the future → clamped to now |
| `host` | string ≤128 | default `unknown` (or `resource.host`) |
| `name` | string ≤128 | metric/event/span name. Metrics: `^[A-Za-z][A-Za-z0-9_.:/-]{0,127}$`; a leading `_` is reserved |
| `level` | string | logs: `debug` `info` `warn` `error` `fatal` (synonyms such as `warning`, `err`, `critical` are normalised) |
| `msg` | string ≤2048 | log/event text |
| `type` | string | metrics: `counter` \| `gauge` \| `histogram` |
| `value` | number | metrics/spans (`ms`). Counters must be ≥ 0 and are *deltas*, not running totals |
| `n` | int | histogram: the value was observed `n` times (pre-aggregated) |
| `unit` | string ≤32 | e.g. `ms`, `bytes` |
| `tags` | object | metric dimensions — **low cardinality**: ≤ 8 keys, key `[a-z_][a-z0-9_]{0,31}`, value ≤ 64 chars |
| `attrs` | object | free-form context for logs/events/spans (≤ 32 keys); not aggregated |
| `resource` | object | `{service, env, version, host}`; batch-level value fills items lacking one |
| `trace_id` `span_id` `parent_id` | string | spans |
| `status` | string | spans: `ok` \| `error` |

Example batch:

```json
{"resource":{"service":"checkout","env":"prod","version":"1.4.2","host":"web-1"},
 "events":[
  {"kind":"metric","type":"counter","name":"orders.placed","value":1,"tags":{"region":"eu"}},
  {"kind":"metric","type":"histogram","name":"db.query_ms","value":12.5,"unit":"ms"},
  {"kind":"log","level":"error","msg":"checkout failed","attrs":{"order":"o-123"}}
 ]}
```

## 4. Limits (defaults; the operator may tune)

| Limit | Default |
|-------|---------|
| Decoded body per request | 1 MiB |
| Events per request | 1000 |
| One event (serialised) | 16 KiB |
| Sustained rate per app key | 5000 events/s (burst 25 000) |
| Active metric series per app | 2000; 200 per metric name (overflow folds into `tag=_overflow`, counts preserved) |
| Event age accepted | ≤ 24 h in the past |

## 5. Responses

| Status | Meaning | Client action |
|--------|---------|---------------|
| `202` | `{"ok":true,"accepted":N,"rejected":M?,"errors":[{"i":idx,"error":"…"}]?}` | done |
| `200` | OTLP with `partialSuccess` | done |
| `400` | invalid payload (atomic) or nothing valid | fix; **do not retry** |
| `401` | missing/bad/revoked key | fix config; do not retry |
| `413` | body or item count over limit | split the batch |
| `415` | OTLP protobuf | use OTLP JSON |
| `429` | rate limited; `Retry-After: <s>` header | back off, retry |
| `502`/`503` | hub temporarily unable to accept; often `Retry-After` | back off, retry |

Recommended retry policy: exponential backoff 0.3 s → 10 s with 0–50 % jitter,
≤ 4 retries, then drop and count.

## 6. Delivery semantics

At-most-once from the client's view (bounded queue, drop on failure);
at-least-once across a retried request (a retry after a lost `202` may double
count a counter). Counters are deltas: prefer few, larger batches.

## 7. Versioning

`/ingest/v1/` and envelope `v:1` are additive-only. New optional fields may
appear in later minor versions. **Unknown fields on an event are rejected today** (`400`) —
put extra context in `attrs`, never as new top-level keys.
