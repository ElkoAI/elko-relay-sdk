# Relay Telemetry — Go client

Requires: Go 1.22+.

## Install
Copy `relaytelem.go` into your project (package `relaytelem`) or import the module path once the repo is published.

## Configure
```bash
export RELAY_URL=https://relay.example.com
export RELAY_APP_KEY=rk_your_app_key
export RELAY_TELEM_ENABLED=1     # no-op until set
# optional: RELAY_TELEM_SERVICE, RELAY_TELEM_ENV, RELAY_TELEM_VERSION, RELAY_TELEM_HOST
```

## Hello
```go
t := relaytelem.FromEnv()
defer t.Close()                       // flush on exit
t.Counter("orders.placed", 1, relaytelem.Tags{"region": "eu"})
done := t.Timer("db.query_ms", nil); runQuery(); done()   // records elapsed ms
t.Log("error", "checkout failed", nil)
```

Calls never block or raise; events are queued (bounded), batched, gzip'd and POSTed
to `/ingest/v1/batch` with retry/backoff. Counters are **deltas**. Keep tags
low-cardinality ([guide](../docs/tagging-and-cardinality.md)). Wire contract: [SPEC.md](../SPEC.md).

## Try it
```bash
cd go && go test ./... && go run ./example
```
