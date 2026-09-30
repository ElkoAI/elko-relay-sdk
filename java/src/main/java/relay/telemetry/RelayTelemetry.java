package relay.telemetry;

import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.atomic.AtomicLong;
import java.util.zip.GZIPOutputStream;

/**
 * Elko Relay telemetry client. Java 11+, JDK only (no dependencies).
 *
 * <pre>
 * RelayTelemetry t = RelayTelemetry.fromEnv();  // RELAY_URL, RELAY_APP_KEY, RELAY_TELEM_ENABLED=1
 * t.counter("orders.placed", 1, Map.of("region", "eu"));
 * t.gauge("queue.depth", 42, null);
 * try (var timer = t.timer("db.query_ms", null)) { ... }
 * t.log("error", "checkout failed", null);
 * t.close();   // flush on exit (a JVM shutdown hook also does this)
 * </pre>
 *
 * Non-blocking: calls offer to a bounded queue (oldest dropped when full). A
 * daemon thread POSTs gzip'd batches to /ingest/v1/batch with retry + backoff.
 */
public final class RelayTelemetry implements AutoCloseable {
    private final String url, appKey, resourceJson;
    private final boolean active;
    private final int retries = 4;
    private final long flushEveryMs = 2000;
    private final ArrayBlockingQueue<String> q;
    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3)).build();
    private final Random rnd = new Random();
    private final Thread worker;
    private volatile boolean closed;
    private final Object wake = new Object();
    private final AtomicLong dropped = new AtomicLong(), sent = new AtomicLong();

    public RelayTelemetry(String url, String appKey, boolean enabled, String host, String service,
                          String env, String version, int maxQueue) {
        this.url = url == null ? "" : url.replaceAll("/+$", "");
        this.appKey = appKey == null ? "" : appKey;
        this.active = enabled && !this.url.isEmpty() && !this.appKey.isEmpty();
        this.q = new ArrayBlockingQueue<>(Math.max(16, maxQueue));
        StringBuilder r = new StringBuilder("{");
        String[][] kv = {{"service", service}, {"env", env}, {"version", version}, {"host", host}};
        for (String[] p : kv) {
            if (p[1] != null && !p[1].isEmpty()) {
                if (r.length() > 1) r.append(',');
                r.append(str(p[0])).append(':').append(str(p[1]));
            }
        }
        this.resourceJson = r.append('}').toString();
        if (active) {
            worker = new Thread(this::loop, "relay-telemetry");
            worker.setDaemon(true);
            worker.start();
            Runtime.getRuntime().addShutdownHook(new Thread(this::close));
        } else {
            worker = null;
        }
    }

    public static RelayTelemetry fromEnv() {
        String on = env("RELAY_TELEM_ENABLED").trim().toLowerCase();
        String host = env("RELAY_TELEM_HOST");
        if (host.isEmpty()) {
            try { host = java.net.InetAddress.getLocalHost().getHostName(); } catch (Exception e) { host = "java"; }
        }
        return new RelayTelemetry(env("RELAY_URL"), env("RELAY_APP_KEY"),
                on.equals("1") || on.equals("true") || on.equals("yes") || on.equals("on"), host,
                env("RELAY_TELEM_SERVICE"), env("RELAY_TELEM_ENV"), env("RELAY_TELEM_VERSION"), 10000);
    }

    private static String env(String k) { String v = System.getenv(k); return v == null ? "" : v; }

    public long sent() { return sent.get(); }
    public long dropped() { return dropped.get(); }

    // -- api ---------------------------------------------------------------
    public void counter(String name, double delta, Map<String, ?> tags) { metric("counter", name, delta, "", tags); }
    public void gauge(String name, double value, Map<String, ?> tags) { metric("gauge", name, value, "", tags); }
    public void histogram(String name, double value, String unit, Map<String, ?> tags) { metric("histogram", name, value, unit, tags); }

    /** try-with-resources timer; records elapsed ms as a histogram on close(). */
    public AutoCloseable timer(String name, Map<String, ?> tags) {
        long t0 = System.nanoTime();
        return () -> histogram(name, (System.nanoTime() - t0) / 1e6, "ms", tags);
    }

    public void log(String level, String msg, Map<String, ?> tags) {
        push("{\"kind\":\"log\",\"level\":" + str(level) + ",\"msg\":" + str(msg) + tagsJson(tags));
    }

    public void event(String name, String msg, Map<String, ?> tags) {
        push("{\"kind\":\"event\",\"name\":" + str(name) + ",\"msg\":" + str(msg == null ? "" : msg) + tagsJson(tags));
    }

    public void span(String name, String traceId, String spanId, String parentId, double ms, boolean failed, Map<String, ?> tags) {
        push("{\"kind\":\"span\",\"name\":" + str(name) + ",\"value\":" + num(ms) + ",\"unit\":\"ms\",\"trace_id\":" + str(traceId)
                + ",\"span_id\":" + str(spanId) + (parentId == null || parentId.isEmpty() ? "" : ",\"parent_id\":" + str(parentId))
                + ",\"status\":" + str(failed ? "error" : "ok") + tagsJson(tags));
    }

    public void heartbeat() { push("{\"kind\":\"hb\""); }

    private void metric(String type, String name, double v, String unit, Map<String, ?> tags) {
        push("{\"kind\":\"metric\",\"type\":" + str(type) + ",\"name\":" + str(name) + ",\"value\":" + num(v)
                + (unit == null || unit.isEmpty() ? "" : ",\"unit\":" + str(unit)) + tagsJson(tags));
    }

    // -- internals ---------------------------------------------------------
    /** @param open JSON object text without its closing brace */
    private void push(String open) {
        if (!active || closed) return;
        String e = open + ",\"ts\":\"" + Instant.now() + "\"}";
        while (!q.offer(e)) {          // full: drop oldest, keep newest
            if (q.poll() != null) dropped.incrementAndGet();
        }
        if (q.size() >= 500) synchronized (wake) { wake.notify(); }
    }

    private static String tagsJson(Map<String, ?> tags) {
        if (tags == null || tags.isEmpty()) return "";
        StringBuilder b = new StringBuilder(",\"tags\":{");
        boolean first = true;
        for (Map.Entry<String, ?> en : tags.entrySet()) {
            if (!first) b.append(',');
            first = false;
            b.append(str(en.getKey())).append(':').append(str(String.valueOf(en.getValue())));
        }
        return b.append('}').toString();
    }

    private static String num(double d) { return Double.isFinite(d) ? Double.toString(d) : "0"; }

    static String str(String s) {
        StringBuilder b = new StringBuilder("\"");
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"') b.append("\\\"");
            else if (c == '\\') b.append("\\\\");
            else if (c == '\n') b.append("\\n");
            else if (c == '\r') b.append("\\r");
            else if (c == '\t') b.append("\\t");
            else if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
            else b.append(c);
        }
        return b.append('"').toString();
    }

    private void loop() {
        while (!closed) {
            synchronized (wake) { try { wake.wait(flushEveryMs); } catch (InterruptedException e) { return; } }
            flush();
        }
    }

    /** Send everything queued now (blocking). */
    public void flush() {
        if (!active) return;
        while (true) {
            List<String> batch = new ArrayList<>();
            q.drainTo(batch, 1000);
            if (batch.isEmpty()) return;
            if (post(batch)) sent.addAndGet(batch.size()); else dropped.addAndGet(batch.size());
        }
    }

    @Override public synchronized void close() {
        if (closed) return;
        flush();
        closed = true;
        synchronized (wake) { wake.notifyAll(); }
    }

    private boolean post(List<String> events) {
        try {
            String json = "{\"resource\":" + resourceJson + ",\"events\":[" + String.join(",", events) + "]}";
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            try (GZIPOutputStream gz = new GZIPOutputStream(bo)) { gz.write(json.getBytes(java.nio.charset.StandardCharsets.UTF_8)); }
            byte[] body = bo.toByteArray();
            double delay = 0.3;
            for (int attempt = 0; attempt <= retries; attempt++) {
                double wait = delay;
                try {
                    HttpRequest req = HttpRequest.newBuilder(URI.create(url + "/ingest/v1/batch"))
                            .timeout(Duration.ofSeconds(5))
                            .header("Authorization", "Bearer " + appKey)
                            .header("Content-Type", "application/json")
                            .header("Content-Encoding", "gzip")
                            .POST(HttpRequest.BodyPublishers.ofByteArray(body)).build();
                    HttpResponse<Void> r = http.send(req, HttpResponse.BodyHandlers.discarding());
                    int c = r.statusCode();
                    if (c == 200 || c == 202) return true;
                    if (c >= 400 && c < 500 && c != 429) return false; // retrying cannot help
                    String ra = r.headers().firstValue("Retry-After").orElse("");
                    if (ra.matches("\\d+") && Integer.parseInt(ra) > 0) wait = Integer.parseInt(ra);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    return false;
                } catch (Exception ignored) { /* network error: retry */ }
                if (attempt < retries) {
                    try { Thread.sleep((long) ((wait + rnd.nextDouble() * wait * 0.5) * 1000)); }
                    catch (InterruptedException ie) { Thread.currentThread().interrupt(); return false; }
                    delay = Math.min(delay * 2, 10);
                }
            }
        } catch (Exception ignored) { }
        return false;
    }
}
