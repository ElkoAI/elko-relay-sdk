# Relay Telemetry — Java client

Requires: Java 11+, JDK only.

## Install
Copy `RelayTelemetry.java` into your source tree or build with the included `pom.xml`.

## Configure
```bash
export RELAY_URL=https://relay.example.com
export RELAY_APP_KEY=rk_your_app_key
export RELAY_TELEM_ENABLED=1     # no-op until set
# optional: RELAY_TELEM_SERVICE, RELAY_TELEM_ENV, RELAY_TELEM_VERSION, RELAY_TELEM_HOST
```

## Hello
```java
RelayTelemetry t = RelayTelemetry.fromEnv();
t.counter("orders.placed", 1, Map.of("region", "eu"));
try (var timer = t.timer("db.query_ms", null)) { runQuery(); }
t.log("error", "checkout failed", null);
t.close();                            // flush on exit (a shutdown hook also does it)
```

Calls never block or raise; events are queued (bounded), batched, gzip'd and POSTed
to `/ingest/v1/batch` with retry/backoff. Counters are **deltas**. Keep tags
low-cardinality ([guide](../docs/tagging-and-cardinality.md)). Wire contract: [SPEC.md](../SPEC.md).

## Try it
```bash
cd java && javac --release 11 -d out src/main/java/relay/telemetry/*.java && java -cp out relay.telemetry.Example
```
