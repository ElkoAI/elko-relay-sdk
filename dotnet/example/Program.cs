// dotnet run --project example   (RELAY_URL, RELAY_APP_KEY, RELAY_TELEM_ENABLED=1)
using Relay.Telemetry;

var t = RelayTelemetry.FromEnv();
t.Event("demo.started", "hello from .NET");
for (var i = 0; i < 20; i++)
{
    using (t.Timer("demo.work_ms", ("step", "compute"))) Thread.Sleep(10 + i * 5);
    t.Counter("demo.iterations");
    t.Gauge("demo.progress", (i + 1) * 5.0);
}
t.Log("info", "demo finished");
t.Heartbeat();
t.Dispose(); // flush on exit
Console.WriteLine($"sent={t.Sent} dropped={t.Dropped}");
