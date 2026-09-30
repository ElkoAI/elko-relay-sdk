# Relay Telemetry — curl / bash

Requires: bash + curl.

```bash
export RELAY_URL=https://relay.example.com RELAY_APP_KEY=rk_your_app_key RELAY_TELEM_ENABLED=1
. ./relay-telem.sh
relay_counter orders.placed 1 region=eu
relay_gauge   queue.depth 42
relay_histogram db.query_ms 12.5
relay_log error "checkout failed"
relay_event deploy.finished "v1.4.2"
relay_hb
printf '%s\n' '{"kind":"metric","type":"counter","name":"n","value":1}' | relay_batch
```

One synchronous POST per call; failures are swallowed so your script never breaks.
CLI form: `./relay-telem.sh counter orders.placed 1 region=eu`.
`./smoke.sh` sends one of every kind and prints the HTTP status of each.
