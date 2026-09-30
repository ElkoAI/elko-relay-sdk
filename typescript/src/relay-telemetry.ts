/**
 * Elko Relay telemetry client — Node 18+, zero dependencies.
 * Non-blocking queue → background batch POST (gzip) → retry with backoff.
 *
 *   import { fromEnv } from "./relay-telemetry";
 *   const t = fromEnv();                       // RELAY_URL, RELAY_APP_KEY, RELAY_TELEM_ENABLED=1
 *   t.counter("orders.placed", 1, { region: "eu" });
 *   t.gauge("queue.depth", 42);
 *   const done = t.timer("db.query_ms"); done();   // records elapsed ms
 *   t.log("error", "checkout failed");
 *   await t.close();                           // flush on exit (also hooked to beforeExit)
 */
import { gzipSync } from "node:zlib";

export type Tags = Record<string, string | number | boolean>;

export interface Options {
  url?: string;
  appKey?: string;
  enabled?: boolean;
  host?: string;
  service?: string;
  env?: string;
  version?: string;
  maxQueue?: number; // default 10000 (oldest dropped)
  flushEveryMs?: number; // default 2000
  flushAt?: number; // default 500
  retries?: number; // default 4
  timeoutMs?: number; // default 5000
  onError?: (e: Error) => void;
}

type Ev = Record<string, unknown>;
const truthy = (s?: string) => ["1", "true", "yes", "on"].includes((s ?? "").trim().toLowerCase());
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class Client {
  private q: Ev[] = [];
  private tick?: NodeJS.Timeout;
  private flushing?: Promise<void>;
  private closed = false;
  dropped = 0;
  sent = 0;
  private readonly o: Required<Omit<Options, "onError">> & { onError?: (e: Error) => void };

  constructor(o: Options = {}) {
    this.o = {
      url: (o.url ?? "").replace(/\/+$/, ""),
      appKey: o.appKey ?? "",
      enabled: o.enabled ?? false,
      host: o.host ?? "",
      service: o.service ?? "",
      env: o.env ?? "",
      version: o.version ?? "",
      maxQueue: o.maxQueue ?? 10000,
      flushEveryMs: o.flushEveryMs ?? 2000,
      flushAt: o.flushAt ?? 500,
      retries: o.retries ?? 4,
      timeoutMs: o.timeoutMs ?? 5000,
      onError: o.onError,
    };
    if (this.active) {
      this.tick = setInterval(() => void this.flush(), this.o.flushEveryMs);
      this.tick.unref(); // never keep the process alive just for telemetry
      process.once("beforeExit", () => void this.close());
    }
  }

  private get active() { return this.o.enabled && !!this.o.url && !!this.o.appKey; }

  private push(e: Ev) {
    if (!this.active || this.closed) return;
    e.ts = new Date().toISOString();
    if (this.q.length >= this.o.maxQueue) { this.q.shift(); this.dropped++; }
    this.q.push(e);
    if (this.q.length >= this.o.flushAt) void this.flush();
  }

  counter(name: string, delta = 1, tags?: Tags) { this.push({ kind: "metric", type: "counter", name, value: delta, tags }); }
  gauge(name: string, value: number, tags?: Tags) { this.push({ kind: "metric", type: "gauge", name, value, tags }); }
  histogram(name: string, value: number, unit = "", tags?: Tags) { this.push({ kind: "metric", type: "histogram", name, value, unit, tags }); }
  /** Returns a function; call it to record elapsed ms. */
  timer(name: string, tags?: Tags): () => void {
    const t0 = process.hrtime.bigint();
    return () => this.histogram(name, Number(process.hrtime.bigint() - t0) / 1e6, "ms", tags);
  }
  log(level: "debug" | "info" | "warn" | "error", msg: string, tags?: Tags) { this.push({ kind: "log", level, msg, tags }); }
  event(name: string, msg = "", tags?: Tags) { this.push({ kind: "event", name, msg, tags }); }
  span(name: string, traceId: string, spanId: string, ms: number, failed = false, parentId?: string, tags?: Tags) {
    this.push({ kind: "span", name, value: ms, unit: "ms", trace_id: traceId, span_id: spanId, parent_id: parentId, status: failed ? "error" : "ok", tags });
  }
  heartbeat() { this.push({ kind: "hb" }); }

  /** Send everything queued; resolves when done. Never rejects. */
  flush(): Promise<void> {
    if (!this.active) return Promise.resolve();
    if (!this.flushing) {
      this.flushing = this.drain().finally(() => { this.flushing = undefined; });
    }
    return this.flushing;
  }

  async close(): Promise<void> {
    if (this.closed) return;
    await this.flush();
    this.closed = true;
    if (this.tick) clearInterval(this.tick);
    await this.flush();
  }

  private resource() {
    const r: Record<string, string> = {};
    if (this.o.service) r.service = this.o.service;
    if (this.o.env) r.env = this.o.env;
    if (this.o.version) r.version = this.o.version;
    if (this.o.host) r.host = this.o.host;
    return r;
  }

  private async drain() {
    while (this.q.length) {
      const batch = this.q.splice(0, 1000);
      if (await this.post(batch)) this.sent += batch.length; else this.dropped += batch.length;
    }
  }

  private async post(batch: Ev[]): Promise<boolean> {
    const body = gzipSync(JSON.stringify({ resource: this.resource(), events: batch }));
    let delay = 300;
    for (let attempt = 0; attempt <= this.o.retries; attempt++) {
      let wait = delay;
      try {
        const res = await fetch(`${this.o.url}/ingest/v1/batch`, {
          method: "POST",
          headers: { Authorization: `Bearer ${this.o.appKey}`, "Content-Type": "application/json", "Content-Encoding": "gzip" },
          body,
          signal: AbortSignal.timeout(this.o.timeoutMs),
        });
        await res.arrayBuffer();
        if (res.status === 202 || res.status === 200) return true;
        if (res.status === 429 || res.status >= 500) {
          const ra = Number(res.headers.get("retry-after"));
          if (ra > 0) wait = ra * 1000;
        } else {
          this.o.onError?.(new Error(`relay-telemetry: hub returned HTTP ${res.status}`));
          return false; // 4xx: retrying cannot help
        }
      } catch (e) {
        if (attempt === this.o.retries) this.o.onError?.(e as Error);
      }
      if (attempt < this.o.retries) {
        await sleep(wait + Math.random() * wait * 0.5);
        delay = Math.min(delay * 2, 10000);
      }
    }
    return false;
  }
}

export function fromEnv(): Client {
  const e = process.env;
  return new Client({
    url: e.RELAY_URL, appKey: e.RELAY_APP_KEY, enabled: truthy(e.RELAY_TELEM_ENABLED),
    host: e.RELAY_TELEM_HOST || require("node:os").hostname(),
    service: e.RELAY_TELEM_SERVICE, env: e.RELAY_TELEM_ENV, version: e.RELAY_TELEM_VERSION,
  });
}
