# Relay Telemetry — .NET (C#) client

Requires: .NET 6+, BCL only (**not compiled in the authoring environment yet — please run `dotnet build` and report issues**).

## Install
Copy `src/RelayTelemetry.cs` or reference `RelayTelemetry.csproj`.

## Configure
```bash
export RELAY_URL=https://relay.example.com
export RELAY_APP_KEY=rk_your_app_key
export RELAY_TELEM_ENABLED=1     # no-op until set
# optional: RELAY_TELEM_SERVICE, RELAY_TELEM_ENV, RELAY_TELEM_VERSION, RELAY_TELEM_HOST
```

## Hello
```csharp
var t = RelayTelemetry.FromEnv();
t.Counter("orders.placed", 1, ("region", "eu"));
using (t.Timer("db.query_ms")) { RunQuery(); }
t.Log("error", "checkout failed");
t.Dispose();                          // flush on exit (also on ProcessExit)
```

Calls never block or raise; events are queued (bounded), batched, gzip'd and POSTed
to `/ingest/v1/batch` with retry/backoff. Counters are **deltas**. Keep tags
low-cardinality ([guide](../docs/tagging-and-cardinality.md)). Wire contract: [SPEC.md](../SPEC.md).

## Try it
```bash
cd dotnet && dotnet build && dotnet run --project example
```
