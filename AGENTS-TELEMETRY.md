# AGENTS-TELEMETRY.md — instrument an existing app with Elko Relay telemetry

Instructions for a coding agent. Goal: add Elko Relay telemetry (heartbeat, logs,
metrics, events) to the **host application** you were pointed at, with minimal,
safe, reviewable changes. This file is deliberately *not* named `AGENTS.md` so it
never collides with the host app's own `AGENTS.md`.

- SDK repo: <https://github.com/ElkoAI/elko-relay-sdk> (Apache-2.0), pinned tag **`v0.1.0`**
- Wire contract: [SPEC.md](./SPEC.md) · tags: [docs/tagging-and-cardinality.md](./docs/tagging-and-cardinality.md)
- The hosted Elko Relay is **not publicly available yet**. `RELAY_URL` points at the
  user's **own hub** (examples use `https://relay.example.com`). If the user has no
  hub or app key, add the code (it is a no-op when disabled), skip live verification, and say so.

## 1. Bootstrap

1. Detect the host app's language(s) from manifests: `go.mod` → go, `package.json` → typescript (Node 18+),
   `pyproject.toml`/`requirements.txt` → python, `composer.json` → php, `pom.xml`/`build.gradle` → java,
   `*.csproj` → dotnet, `Gemfile` → ruby, `Cargo.toml` → rust, only shell scripts/cron → curl.
   Polyglot repo: instrument the main long-running service first; one SDK per language actually used.
2. Fetch the SDK into a temp dir **outside the app tree**:
   ```bash
   T=$(mktemp -d) && git clone --depth 1 --branch v0.1.0 https://github.com/ElkoAI/elko-relay-sdk "$T/sdk"
   ```
3. Copy **only** the matching language folder's runtime file(s) into the app in an idiomatic place
   (not tests, examples, `node_modules`, build output):

   | Lang | Copy | Suggested destination |
   |------|------|-----------------------|
   | go | `go/relaytelem.go` | `internal/relaytelem/relaytelem.go` (package `relaytelem`) |
   | typescript | `typescript/src/relay-telemetry.ts` | `src/lib/relay-telemetry.ts` |
   | python | `python/relay_telemetry/` | next to the app's top-level package |
   | php | `php/src/Client.php` (namespace `Relay\Telemetry`) | `src/Telemetry/Client.php` (or `composer` path repo) |
   | java | `java/src/main/java/relay/telemetry/RelayTelemetry.java` | `src/main/java/relay/telemetry/` |
   | dotnet | `dotnet/src/RelayTelemetry.cs` (**untested**, run `dotnet build`) | `Telemetry/RelayTelemetry.cs` |
   | ruby | `ruby/lib/relay_telemetry.rb` | `lib/relay_telemetry.rb` |
   | rust | `rust/src/lib.rs` as a module, or path/git dependency; needs `ureq`, `flate2`, `serde_json` | `src/relay_telemetry.rs` |
   | curl | `curl/relay-telem.sh` | `scripts/relay-telem.sh` |

   Keep the Apache-2.0 header in copied files. Adjust package/namespace declarations only if the build requires it.
   Do not add any other dependency; the SDKs use the standard library.
4. Delete the temp clone: `rm -rf "$T"`. Never leave the clone (or a nested `.git`) inside the app.

Fallbacks:
- **No git**: `curl -fsSL https://github.com/ElkoAI/elko-relay-sdk/archive/refs/tags/v0.1.0.tar.gz | tar -xz -C "$T" --wildcards '*/go/*' '*/SPEC.md'`
  (replace `go` with the language folder), or fetch single files from
  `https://raw.githubusercontent.com/ElkoAI/elko-relay-sdk/v0.1.0/<path>`.
- **No network**: stop and report; do not write a client from memory.

## 2. Configuration

| Env var | Meaning |
|---------|---------|
| `RELAY_URL` | the user's hub base URL, e.g. `https://relay.example.com` |
| `RELAY_APP_KEY` | app key `rk_...` (Relay Admin → Apps; shown once) |
| `RELAY_TELEM_ENABLED` | `1`/`true` to turn on; **unset = silent no-op** |
| `RELAY_TELEM_SERVICE`, `RELAY_TELEM_ENV`, `RELAY_TELEM_VERSION`, `RELAY_TELEM_HOST` | optional resource attributes |

- **Never** hardcode, log, or commit a key. Add the names with placeholder values to `.env.example` (or the
  app's equivalent config template) only. Confirm real `.env` files are git-ignored.
- Read config via the SDK's `from_env()` / `FromEnv()`; do not build a second config system.

## 3. Instrumentation checklist (do in this order; stop when the app is well covered)

1. **Heartbeat** — call `heartbeat` on startup and then every 30–60 s from an existing scheduler/timer/loop
   (drives Stopped/Recovered alerts).
2. **Error / warn logs** — hook the app's logger (handler, appender, middleware, panic/uncaught-exception hook)
   to send `error` and `warn` (never debug/info flood). Send a short message; put no user data in it.
3. **HTTP/edge layer** (one middleware, not per-handler):
   - `http.request_ms` histogram (unit ms), tags `route` (the route *template*, e.g. `/orders/:id`), `method`, `status_class` (`2xx`…`5xx`)
   - `http.requests` counter, same tags; `http.errors` counter for 5xx.
4. **Key business events** — 3–10 max (signup, order placed, payment failed, deploy finished) as `counter` and/or `event`.
5. **Background jobs** — `job.duration_ms` histogram + `job.runs` / `job.failures` counters, tag `job` (job name).
6. **Gauges** — `queue.depth`, pool sizes, cache size, sampled every 10–60 s (not per request).

Naming: dotted lowercase (`db.query_ms`), unit in name or `unit`. Counters send the **delta** (≥ 0).

**Tags must be bounded** (small fixed sets): route templates, method, status class, job name, region, plan tier.
**Never** tag with user/session/request/order ids, emails, IPs, full URLs or query strings, timestamps, exception text
or any free text. Anything unbounded goes in log/event `attrs`, not tags. Hard caps (SPEC §4): ≤ 8 tag keys,
values ≤ 64 chars, ≤ 200 series per metric name, ≤ 2000 per app; beyond that the hub folds into `_overflow`
and you lose the breakdown. Estimate series = product of each tag's distinct values; keep it under ~50 per metric.

## 4. Safety rules (non-negotiable)

- Telemetry must **never block, throw, or crash** the app. Do not `await` it on a request path; wrap any
  custom glue in try/catch and swallow errors. Do not add retries of your own.
- Use the SDK's async, batched, bounded queue; make sure it is **flushed on shutdown** (`Close()`/`close()`/`defer`,
  signal handler, or the SDK's built-in exit hook — verify which one your language relies on).
- **No secrets, PII, tokens, passwords, cookies, auth headers, request/response bodies** in metric names, tags, log
  messages, or attrs. Redact before logging; when unsure, leave it out.
- **Sample hot paths** (e.g. record 1 in N of very high-rate calls, or aggregate to a counter) — target well under
  the 5000 events/s per-key limit; an app doing >200 req/s should sample the latency histogram.
- With `RELAY_TELEM_ENABLED` unset the app must behave identically and start without a hub, key, or network.
- Do not change existing behavior, public APIs, or dependencies beyond adding the copied file(s) and call sites.

## 5. Snippets (real APIs of each SDK; `t` = client from env)

**Go**
```go
t := relaytelem.FromEnv(); defer t.Close()
t.Heartbeat()
t.Counter("http.requests", 1, relaytelem.Tags{"route": "/orders", "status_class": "2xx"})
done := t.Timer("job.duration_ms", relaytelem.Tags{"job": "sync"}); doWork(); done()
t.Log("error", "checkout failed", nil)
```
**TypeScript / Node**
```ts
import { fromEnv } from "./lib/relay-telemetry"; const t = fromEnv();
t.heartbeat();
t.counter("http.requests", 1, { route: "/orders", status_class: "2xx" });
const done = t.timer("job.duration_ms", { job: "sync" }); await work(); done();
t.log("error", "checkout failed"); process.on("SIGTERM", async () => { await t.close(); process.exit(0); });
```
**Python**
```python
from relay_telemetry import from_env; t = from_env()          # flushed via atexit
t.heartbeat()
t.counter("http.requests", 1, route="/orders", status_class="2xx")
with t.timer("job.duration_ms", job="sync"): do_work()
t.log("error", "checkout failed")
```
**PHP**
```php
$t = \Relay\Telemetry\Client::fromEnv();                       // sent at shutdown
$t->heartbeat();
$t->counter('http.requests', 1, ['route' => '/orders', 'status_class' => '2xx']);
$done = $t->timer('job.duration_ms', ['job' => 'sync']); doWork(); $done();
$t->log('error', 'checkout failed');
```
**Java**
```java
RelayTelemetry t = RelayTelemetry.fromEnv();                   // shutdown hook flushes
t.heartbeat();
t.counter("http.requests", 1, Map.of("route", "/orders", "status_class", "2xx"));
try (var x = t.timer("job.duration_ms", Map.of("job", "sync"))) { doWork(); }
t.log("error", "checkout failed", null);
```
**.NET** (untested SDK)
```csharp
var t = RelayTelemetry.FromEnv();                              // flush on ProcessExit / t.Dispose()
t.Heartbeat();
t.Counter("http.requests", 1, ("route", "/orders"), ("status_class", "2xx"));
using (t.Timer("job.duration_ms", ("job", "sync"))) { DoWork(); }
t.Log("error", "checkout failed");
```
**Ruby**
```ruby
require "relay_telemetry"; t = RelayTelemetry.from_env         # flushed at_exit
t.heartbeat
t.counter("http.requests", 1, route: "/orders", status_class: "2xx")
t.timer("job.duration_ms", job: "sync") { do_work }
t.log(:error, "checkout failed")
```
**Rust**
```rust
let t = relay_telemetry::Client::from_env();                   // Drop flushes; or t.close()
t.heartbeat();
t.counter("http.requests", 1.0, &[("route", "/orders"), ("status_class", "2xx")]);
{ let _g = t.timer("job.duration_ms", &[("job", "sync")]); do_work(); }
t.log("error", "checkout failed", &[]);
```
**curl / shell** (one synchronous POST per call; errors swallowed)
```bash
. ./scripts/relay-telem.sh
relay_hb
relay_counter http.requests 1 route=/orders status_class=2xx
relay_gauge queue.depth 42
relay_log error "checkout failed"
```
Also available in every SDK: `gauge`, `histogram`, `event`, `span`, `flush`. Create the client **once** per process
(module singleton / DI), not per request.

## 6. Verification

1. Build/compile and run the app's existing tests; they must pass unchanged with `RELAY_TELEM_ENABLED` unset.
2. With a real hub: `export RELAY_URL=https://relay.example.com RELAY_APP_KEY=rk_... RELAY_TELEM_ENABLED=1`, then either
   - **curl smoke** (works for any language; expects `HTTP 202` for each line):
     `RELAY_URL=... RELAY_APP_KEY=... bash <(curl -fsSL https://raw.githubusercontent.com/ElkoAI/elko-relay-sdk/v0.1.0/curl/smoke.sh)`
   - or run the app / a small script that exercises the instrumented paths, and let it exit cleanly (flush).
3. Confirm data arrived: Relay **Admin → Telemetry** page shows the app (heartbeat, series, logs), or run
   `/metrics <app>` in a Relay channel and check the card lists your metric names.
4. Confirm no `cap hit` / `_overflow` indicator (that means a tag is too high-cardinality — fix the tag).
5. Never paste the real key into commits, PRs, chat, or your report.

## 7. Host AGENTS.md pointer block

Append this exact block to the **host app's own** `AGENTS.md` (create the file if absent; do not edit anything else in it):

```markdown
## Telemetry (Elko Relay)
Telemetry follows https://github.com/ElkoAI/elko-relay-sdk/blob/v0.1.0/AGENTS-TELEMETRY.md (tag v0.1.0). Client lives at <path/to/copied/client>.
Config via env only: RELAY_URL, RELAY_APP_KEY, RELAY_TELEM_ENABLED (unset = off). Never commit keys; never log secrets/PII.
Metric/log tags must be bounded (route templates, status classes, job names; never ids, emails, IPs, URLs, free text).
```
Replace `<path/to/copied/client>` with the real path.

## 8. Report template (print when done)

```text
Elko Relay telemetry — done
Language(s): <go|typescript|...>   SDK: elko-relay-sdk v0.1.0
Files added:    <paths>
Files changed:  <paths + one-line reason each>  (.env.example, AGENTS.md, entrypoint, middleware...)
Metrics added:  <name (type) tags=[...] ...>
Logs/events:    <what is sent, at which levels>
Heartbeat:      <where/interval>
Safety:         disabled when RELAY_TELEM_ENABLED unset: yes/no; flush on shutdown: <how>; sampling: <where>
Verified:       <tests pass w/ telemetry off> ; <smoke/hub check + what was seen in Admin→Telemetry or /metrics> | NOT verified (reason)
Follow-ups:     <e.g. user must set RELAY_URL/RELAY_APP_KEY in deployment>
```
