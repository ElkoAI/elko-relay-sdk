# Elko Relay SDK

Telemetry SDKs for **Elko Relay**.

Tiny, dependency-free clients for sending **logs, metrics, events, spans and
heartbeats** to an Elko Relay hub over plain HTTPS. One wire contract
([SPEC.md](./SPEC.md)), nine ways to speak it.

> Status: **pre-release / beta** · v0.1 · License: **Apache-2.0** (see [LICENSE](./LICENSE) and [NOTICE](./NOTICE))
>
> **The hosted Elko Relay service is not publicly available yet.** These SDKs speak an
> open wire contract ([SPEC.md](./SPEC.md)); point `RELAY_URL` at your own hub.
> All examples use the placeholder host `https://relay.example.com` — substitute your hub.
>
> **.NET note:** the C# client is pre-release and has not been built or tested yet.

| Language | Dir | Install | Tested here |
|----------|-----|---------|-------------|
| Go | [`go/`](./go) | copy `relaytelem.go` or `go get` the module | unit tests + local smoke |
| TypeScript / Node 18+ | [`typescript/`](./typescript) | copy `src/relay-telemetry.ts` | compile + local smoke |
| Python 3.8+ | [`python/`](./python) | copy `relay_telemetry/` | unit tests |
| PHP 8+ | [`php/`](./php) | copy `src/Client.php` or composer | smoke vs mock |
| Java 11+ | [`java/`](./java) | copy `RelayTelemetry.java` | compile + local smoke |
| .NET 6+ (C#) | [`dotnet/`](./dotnet) | copy `src/RelayTelemetry.cs` | **untested / not built yet (pre-release)** |
| Ruby 2.7+ | [`ruby/`](./ruby) | copy `lib/relay_telemetry.rb` | unit tests |
| Rust | [`rust/`](./rust) | `cargo add` / copy `src/lib.rs` | unit tests |
| curl / bash | [`curl/`](./curl) | source `relay-telem.sh` | local smoke |

## Configure (all languages)

```bash
export RELAY_URL=https://relay.example.com   # your hub
export RELAY_APP_KEY=rk_your_app_key         # from Admin → Apps (shown once; keep secret)
export RELAY_TELEM_ENABLED=1                 # the SDK is a silent no-op until this is on
# optional resource attributes stamped on every event:
# RELAY_TELEM_SERVICE=checkout RELAY_TELEM_ENV=prod RELAY_TELEM_VERSION=1.4.2 RELAY_TELEM_HOST=web-1
```

## Hello (Python; every SDK has the same shape)

```python
from relay_telemetry import from_env
t = from_env()
t.counter("orders.placed", 1, region="eu")
with t.timer("db.query_ms"): run_query()
t.log("error", "checkout failed")      # flushed at exit, or t.close()
```

## Using an AI agent

Point a coding agent at this repo and ask it to follow
[AGENTS-TELEMETRY.md](./AGENTS-TELEMETRY.md): it copies the one matching SDK into your app (pinned to
tag `v0.1.0`), wires config through env vars, instruments the essentials with bounded tags, and reports what it did.

## Design rules every SDK follows

- **Never blocks or throws** into your app: calls append to a bounded in-memory
  queue (oldest dropped when full; `dropped` counter exposed).
- **Batches** up to 1000 events per `POST /ingest/v1/batch`, gzip'd, every ~2 s
  or 500 queued events, and **flushes on exit**.
- **Retries** network errors, `429` and `5xx` with exponential backoff + jitter and
  honours `Retry-After`. `4xx` (other than 429) is dropped, not retried.
- **Off by default** (`RELAY_TELEM_ENABLED`), so it is safe to ship in libraries.
- No third-party dependencies (Rust needs `ureq`, `flate2`, `serde_json`).

## Docs

- [AGENTS-TELEMETRY.md](./AGENTS-TELEMETRY.md) — instructions for a coding agent to instrument an existing app
- [SPEC.md](./SPEC.md) — the wire contract (envelope, endpoints, limits, errors)
- [docs/LAYERS.md](./docs/LAYERS.md) — start with one curl, grow only as needed (L0 → L6)
- [docs/tagging-and-cardinality.md](./docs/tagging-and-cardinality.md) — what makes a good metric name/tag
- [docs/otlp-and-statsd.md](./docs/otlp-and-statsd.md) — use OpenTelemetry / StatsD instead of an SDK

## Repo hygiene

Nothing here imports hub code, contains keys, or names a private host. Run
`scripts/check-public.sh` before publishing.

## Scripts

- `scripts/check-public.sh` — fails if private hostnames/IPs/keys/hub imports leak in
- `scripts/test-all.sh` — runs every language's tests that has a toolchain installed

## License

Apache-2.0 — see [LICENSE](./LICENSE). Copyright 2026 Elko AI.
