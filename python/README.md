# Relay Telemetry — Python client

Requires: Python 3.8+, stdlib only.

## Install
Copy the `relay_telemetry/` package, or `pip install ./python`.

## Configure
```bash
export RELAY_URL=https://relay.example.com
export RELAY_APP_KEY=rk_your_app_key
export RELAY_TELEM_ENABLED=1     # no-op until set
# optional: RELAY_TELEM_SERVICE, RELAY_TELEM_ENV, RELAY_TELEM_VERSION, RELAY_TELEM_HOST
```

## Hello
```python
from relay_telemetry import from_env
t = from_env()
t.counter("orders.placed", 1, region="eu")
with t.timer("db.query_ms", table="orders"):
    run_query()
t.log("error", "checkout failed")     # flushed via atexit; or t.close()
```

Calls never block or raise; events are queued (bounded), batched, gzip'd and POSTed
to `/ingest/v1/batch` with retry/backoff. Counters are **deltas**. Keep tags
low-cardinality ([guide](../docs/tagging-and-cardinality.md)). Wire contract: [SPEC.md](../SPEC.md).

## Try it
```bash
cd python && python3 -m unittest discover -s tests && python3 example.py
```
