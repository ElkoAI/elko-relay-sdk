// Elko Relay telemetry client. .NET 6+, BCL only (no NuGet dependencies).
//
//   var t = RelayTelemetry.FromEnv();      // RELAY_URL, RELAY_APP_KEY, RELAY_TELEM_ENABLED=1
//   t.Counter("orders.placed", 1, ("region", "eu"));
//   t.Gauge("queue.depth", 42);
//   using (t.Timer("db.query_ms")) { /* work */ }
//   t.Log("error", "checkout failed");
//   t.Dispose();                           // flush on exit (also on ProcessExit)
//
// Non-blocking: calls write to a bounded queue; a background task POSTs gzip'd
// batches to /ingest/v1/batch with retry + backoff.
using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Text;
using System.Text.Json;

namespace Relay.Telemetry;

public sealed class RelayTelemetry : IDisposable
{
    private readonly string _url, _key;
    private readonly bool _active;
    private readonly Dictionary<string, string> _resource = new();
    private readonly LinkedList<Dictionary<string, object?>> _q = new();
    private readonly object _lock = new();
    private readonly int _maxQueue, _retries;
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(5) };
    private readonly CancellationTokenSource _cts = new();
    private readonly SemaphoreSlim _wake = new(0);
    private readonly Task? _worker;
    private bool _closed;
    private long _sent, _dropped;

    public long Sent => Interlocked.Read(ref _sent);
    public long Dropped => Interlocked.Read(ref _dropped);

    public RelayTelemetry(string? url, string? appKey, bool enabled, string? host = null, string? service = null,
                          string? env = null, string? version = null, int maxQueue = 10_000, int retries = 4)
    {
        _url = (url ?? "").TrimEnd('/');
        _key = appKey ?? "";
        _active = enabled && _url.Length > 0 && _key.Length > 0;
        _maxQueue = maxQueue;
        _retries = retries;
        void Put(string k, string? v) { if (!string.IsNullOrEmpty(v)) _resource[k] = v!; }
        Put("service", service); Put("env", env); Put("version", version);
        Put("host", string.IsNullOrEmpty(host) ? Environment.MachineName : host);
        if (_active)
        {
            _worker = Task.Run(LoopAsync);
            AppDomain.CurrentDomain.ProcessExit += (_, _) => Dispose();
        }
    }

    public static RelayTelemetry FromEnv()
    {
        static string E(string k) => Environment.GetEnvironmentVariable(k) ?? "";
        var on = E("RELAY_TELEM_ENABLED").Trim().ToLowerInvariant() is "1" or "true" or "yes" or "on";
        return new RelayTelemetry(E("RELAY_URL"), E("RELAY_APP_KEY"), on, E("RELAY_TELEM_HOST"),
            E("RELAY_TELEM_SERVICE"), E("RELAY_TELEM_ENV"), E("RELAY_TELEM_VERSION"));
    }

    public void Counter(string name, double delta = 1, params (string, string)[] tags) =>
        Push(new() { ["kind"] = "metric", ["type"] = "counter", ["name"] = name, ["value"] = delta }, tags);

    public void Gauge(string name, double value, params (string, string)[] tags) =>
        Push(new() { ["kind"] = "metric", ["type"] = "gauge", ["name"] = name, ["value"] = value }, tags);

    public void Histogram(string name, double value, string unit = "", params (string, string)[] tags) =>
        Push(new() { ["kind"] = "metric", ["type"] = "histogram", ["name"] = name, ["value"] = value, ["unit"] = unit }, tags);

    /// <summary>using-block timer: records elapsed ms as a histogram on dispose.</summary>
    public IDisposable Timer(string name, params (string, string)[] tags)
    {
        var sw = Stopwatch.StartNew();
        return new Scope(() => Histogram(name, sw.Elapsed.TotalMilliseconds, "ms", tags));
    }

    public void Log(string level, string msg, params (string, string)[] tags) =>
        Push(new() { ["kind"] = "log", ["level"] = level, ["msg"] = msg }, tags);

    public void Event(string name, string msg = "", params (string, string)[] tags) =>
        Push(new() { ["kind"] = "event", ["name"] = name, ["msg"] = msg }, tags);

    public void Span(string name, string traceId, string spanId, double ms, bool failed = false,
                     string? parentId = null, params (string, string)[] tags)
    {
        var e = new Dictionary<string, object?>
        {
            ["kind"] = "span", ["name"] = name, ["value"] = ms, ["unit"] = "ms", ["trace_id"] = traceId,
            ["span_id"] = spanId, ["status"] = failed ? "error" : "ok",
        };
        if (!string.IsNullOrEmpty(parentId)) e["parent_id"] = parentId;
        Push(e, tags);
    }

    public void Heartbeat() => Push(new() { ["kind"] = "hb" }, Array.Empty<(string, string)>());

    private sealed class Scope : IDisposable
    {
        private Action? _a;
        public Scope(Action a) => _a = a;
        public void Dispose() { _a?.Invoke(); _a = null; }
    }

    private void Push(Dictionary<string, object?> e, (string, string)[] tags)
    {
        if (!_active || _closed) return;
        if (tags.Length > 0) e["tags"] = tags.ToDictionary(t => t.Item1, t => t.Item2);
        e["ts"] = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'");
        int n;
        lock (_lock)
        {
            if (_q.Count >= _maxQueue) { _q.RemoveFirst(); Interlocked.Increment(ref _dropped); }
            _q.AddLast(e);
            n = _q.Count;
        }
        if (n >= 500) _wake.Release();
    }

    private async Task LoopAsync()
    {
        while (!_cts.IsCancellationRequested)
        {
            try { await _wake.WaitAsync(TimeSpan.FromSeconds(2), _cts.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
            await FlushAsync().ConfigureAwait(false);
        }
    }

    /// <summary>Send everything queued now.</summary>
    public async Task FlushAsync()
    {
        if (!_active) return;
        while (true)
        {
            List<Dictionary<string, object?>> batch;
            lock (_lock)
            {
                batch = _q.Take(1000).ToList();
                for (var i = 0; i < batch.Count; i++) _q.RemoveFirst();
            }
            if (batch.Count == 0) return;
            if (await PostAsync(batch).ConfigureAwait(false)) Interlocked.Add(ref _sent, batch.Count);
            else Interlocked.Add(ref _dropped, batch.Count);
        }
    }

    public void Flush() => FlushAsync().GetAwaiter().GetResult();

    public void Dispose()
    {
        if (_closed) return;
        _closed = true;
        _cts.Cancel();
        try { _worker?.Wait(TimeSpan.FromSeconds(10)); } catch { /* ignore */ }
        Flush();
    }

    private async Task<bool> PostAsync(List<Dictionary<string, object?>> events)
    {
        var json = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object?> { ["resource"] = _resource, ["events"] = events });
        using var ms = new MemoryStream();
        using (var gz = new GZipStream(ms, CompressionLevel.Fastest, true)) gz.Write(json);
        var body = ms.ToArray();
        var delay = 0.3;
        var rnd = new Random();
        for (var attempt = 0; attempt <= _retries; attempt++)
        {
            var wait = delay;
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Post, _url + "/ingest/v1/batch") { Content = new ByteArrayContent(body) };
                req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + _key);
                req.Content.Headers.ContentType = new("application/json");
                req.Content.Headers.ContentEncoding.Add("gzip");
                using var res = await _http.SendAsync(req).ConfigureAwait(false);
                var c = (int)res.StatusCode;
                if (c == 200 || c == 202) return true;
                if (c >= 400 && c < 500 && c != 429) return false; // retrying cannot help
                if (res.Headers.RetryAfter?.Delta is { } ra && ra > TimeSpan.Zero) wait = ra.TotalSeconds;
            }
            catch (Exception) { /* network error: retry */ }
            if (attempt < _retries)
            {
                await Task.Delay(TimeSpan.FromSeconds(wait + rnd.NextDouble() * wait * 0.5)).ConfigureAwait(false);
                delay = Math.Min(delay * 2, 10);
            }
        }
        return false;
    }
}
