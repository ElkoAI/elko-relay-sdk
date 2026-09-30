# Relay Telemetry — Ruby client

Requires: Ruby 2.7+, stdlib only.

## Install
Copy `lib/relay_telemetry.rb` or build the gem from `relay_telemetry.gemspec`.

## Configure
```bash
export RELAY_URL=https://relay.example.com
export RELAY_APP_KEY=rk_your_app_key
export RELAY_TELEM_ENABLED=1     # no-op until set
# optional: RELAY_TELEM_SERVICE, RELAY_TELEM_ENV, RELAY_TELEM_VERSION, RELAY_TELEM_HOST
```

## Hello
```ruby
require "relay_telemetry"
t = RelayTelemetry.from_env
t.counter("orders.placed", 1, region: "eu")
t.timer("db.query_ms", table: "orders") { run_query }
t.log(:error, "checkout failed")      # flushed at_exit; or t.close
```

Calls never block or raise; events are queued (bounded), batched, gzip'd and POSTed
to `/ingest/v1/batch` with retry/backoff. Counters are **deltas**. Keep tags
low-cardinality ([guide](../docs/tagging-and-cardinality.md)). Wire contract: [SPEC.md](../SPEC.md).

## Try it
```bash
cd ruby && ruby test/client_test.rb && ruby -Ilib example.rb
```
