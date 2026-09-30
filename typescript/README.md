# Relay Telemetry — Typescript client

Requires: Node 18+ (global `fetch`, `zlib`).

## Install
Copy `src/relay-telemetry.ts` (or build with `npm run build` and use `dist/`).

## Configure
```bash
export RELAY_URL=https://relay.example.com
export RELAY_APP_KEY=rk_your_app_key
export RELAY_TELEM_ENABLED=1     # no-op until set
# optional: RELAY_TELEM_SERVICE, RELAY_TELEM_ENV, RELAY_TELEM_VERSION, RELAY_TELEM_HOST
```

## Hello
```ts
import { fromEnv } from "./relay-telemetry";
const t = fromEnv();
t.counter("orders.placed", 1, { region: "eu" });
const done = t.timer("db.query_ms"); await runQuery(); done();   // records elapsed ms
t.log("error", "checkout failed");
await t.close();                      // flush on exit (also hooks beforeExit)
```

Calls never block or raise; events are queued (bounded), batched, gzip'd and POSTed
to `/ingest/v1/batch` with retry/backoff. Counters are **deltas**. Keep tags
low-cardinality ([guide](../docs/tagging-and-cardinality.md)). Wire contract: [SPEC.md](../SPEC.md).

## Try it
```bash
cd typescript && npm install && npm run build && node dist/example.js
```
