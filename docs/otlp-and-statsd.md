# Already have OpenTelemetry or StatsD? Skip the SDK.

## OpenTelemetry (OTLP/HTTP **JSON**)

Point an OTLP/HTTP exporter at your hub with JSON encoding and your app key:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://relay.example.com/ingest/v1/otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/json
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer rk_your_app_key"
```

Paths appended by exporters (`/v1/metrics` etc.) map to `/ingest/v1/otlp/metrics`,
`/logs`, `/traces` — if your SDK appends `/v1/…`, set the per-signal endpoint
variables instead (`OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=https://relay.example.com/ingest/v1/otlp/metrics`).

Supported: gauge, sum (delta→counter; cumulative→gauge — set delta temporality: `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta`), histogram (bucket
midpoints), logs, spans. **Not supported:** protobuf (`415`), exponential
histograms, summaries.

## StatsD / DogStatsD (HTTP)

There is no UDP listener. Bridge with curl or a sidecar:

```bash
printf 'web.hits:1|c|#route:/home\nweb.latency:12|ms\n' | curl -fsS -X POST \
  https://relay.example.com/ingest/v1/statsd \
  -H "Authorization: Bearer $RELAY_APP_KEY" --data-binary @-
```

`c` → counter, `g` → gauge, `ms`/`h`/`d` → histogram; `|@rate` scales
counters and histogram counts; `|#k:v` tags follow the tag rules.
