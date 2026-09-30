# Relay Telemetry — Rust client

Requires: Rust 2021, deps `ureq`, `flate2`, `serde_json`.

## Install
Copy `src/lib.rs` into a crate or depend on this directory by path/git.

## Configure
```bash
export RELAY_URL=https://relay.example.com
export RELAY_APP_KEY=rk_your_app_key
export RELAY_TELEM_ENABLED=1     # no-op until set
# optional: RELAY_TELEM_SERVICE, RELAY_TELEM_ENV, RELAY_TELEM_VERSION, RELAY_TELEM_HOST
```

## Hello
```rust
let t = relay_telemetry::Client::from_env();
t.counter("orders.placed", 1.0, &[("region", "eu")]);
{ let _t = t.timer("db.query_ms", &[]); run_query(); }   // records on drop
t.log("error", "checkout failed", &[]);
t.close();                            // flush on exit (also on Drop)
```

Calls never block or raise; events are queued (bounded), batched, gzip'd and POSTed
to `/ingest/v1/batch` with retry/backoff. Counters are **deltas**. Keep tags
low-cardinality ([guide](../docs/tagging-and-cardinality.md)). Wire contract: [SPEC.md](../SPEC.md).

## Try it
```bash
cd rust && cargo test && cargo run --example hello
```
