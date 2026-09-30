# Layers — start small, grow only when it hurts

Each layer is complete on its own. Most apps stop at L1 or L2.

| Layer | What | How | Endpoint |
|-------|------|-----|----------|
| **L0** | "Is it alive?" heartbeat / one-liner | `curl` | `POST /ingest/v1/hb` |
| **L1** | Log lines | pipe any text: `tail -f app.log \| …` or `text/plain` | `POST /ingest/v1/log` |
| **L2** | Metrics (counter, gauge, histogram) | SDK helpers or JSON | `POST /ingest/v1/metric` |
| **L3** | Events (deploys, signups, jobs) | SDK `event()` | `POST /ingest/v1/event` |
| **L4** | Batching & OTLP | SDK default; or OpenTelemetry exporter set to OTLP/HTTP **JSON** | `/ingest/v1/batch`, `/ingest/v1/otlp/*` |
| **L4.5** | StatsD lines | anything that already emits StatsD, over HTTP | `POST /ingest/v1/statsd` |
| **L5** | Direct message bus | for in-cluster producers with bus credentials; same NDJSON envelope | hub operator provides |
| **L6** | Spans-lite | `span()` with trace/span ids; no sampling logic in the SDK | `POST /ingest/v1/span` |

## L0 — one curl

```bash
curl -fsS -X POST https://relay.example.com/ingest/v1/hb \
  -H "Authorization: Bearer $RELAY_APP_KEY" -d '{}'
```

## L1 — text logs

```bash
echo "disk almost full" | curl -fsS -X POST \
  "https://relay.example.com/ingest/v1/log?level=warn&host=web-1" \
  -H "Authorization: Bearer $RELAY_APP_KEY" -H 'Content-Type: text/plain' --data-binary @-
```

## L2 — metric

```bash
curl -fsS -X POST https://relay.example.com/ingest/v1/metric \
  -H "Authorization: Bearer $RELAY_APP_KEY" \
  -d '{"name":"orders.placed","type":"counter","value":1,"tags":{"region":"eu"}}'
```

## L4 — batch (what the SDKs send)

```bash
curl -fsS -X POST https://relay.example.com/ingest/v1/batch \
  -H "Authorization: Bearer $RELAY_APP_KEY" \
  -d '{"resource":{"service":"checkout"},"events":[
        {"kind":"metric","type":"gauge","name":"queue.depth","value":42},
        {"kind":"event","name":"deploy.finished","msg":"v1.4.2"}]}'
```

## L5 — direct bus (advanced)

If you run producers inside the operator's trust boundary you may publish the
same NDJSON envelope straight to the bus subject your operator assigns. This is
operator-specific; ask the hub owner. Everyone else should use HTTP.
