//! Elko Relay telemetry client.
//!
//! ```no_run
//! let t = relay_telemetry::Client::from_env();  // RELAY_URL, RELAY_APP_KEY, RELAY_TELEM_ENABLED=1
//! t.counter("orders.placed", 1.0, &[("region", "eu")]);
//! t.gauge("queue.depth", 42.0, &[]);
//! let done = t.timer("db.query_ms", &[]);  // records ms when dropped
//! drop(done);
//! t.log("error", "checkout failed", &[]);
//! t.close(); // flush on exit (also runs on Drop)
//! ```
//!
//! Non-blocking: calls push to a bounded queue; a background thread POSTs
//! gzip'd batches to /ingest/v1/batch with retry + backoff.
use flate2::{write::GzEncoder, Compression};
use serde_json::{json, Map, Value};
use std::collections::VecDeque;
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

struct Inner {
    url: String,
    key: String,
    active: bool,
    resource: Value,
    q: Mutex<VecDeque<Value>>,
    cv: Condvar,
    max_queue: usize,
    retries: u32,
    closed: AtomicBool,
    sent: AtomicU64,
    dropped: AtomicU64,
}

pub struct Client {
    i: Arc<Inner>,
    worker: Mutex<Option<JoinHandle<()>>>,
}

pub struct Timer<'a> {
    c: &'a Client,
    name: String,
    tags: Vec<(String, String)>,
    t0: Instant,
}
impl Drop for Timer<'_> {
    fn drop(&mut self) {
        let tags: Vec<(&str, &str)> = self.tags.iter().map(|(a, b)| (a.as_str(), b.as_str())).collect();
        self.c.histogram(&self.name, self.t0.elapsed().as_secs_f64() * 1000.0, "ms", &tags);
    }
}

fn now_rfc3339() -> String {
    // UTC, millisecond precision, without a date crate.
    let d = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    let (secs, ms) = (d.as_secs() as i64, d.subsec_millis());
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    // civil-from-days (Howard Hinnant)
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let dd = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z", y, m, dd, rem / 3600, rem % 3600 / 60, rem % 60, ms)
}

fn env(k: &str) -> String {
    std::env::var(k).unwrap_or_default()
}

impl Client {
    pub fn new(url: &str, app_key: &str, enabled: bool, host: &str, service: &str, env_name: &str, version: &str) -> Client {
        let mut res = Map::new();
        for (k, v) in [("service", service), ("env", env_name), ("version", version), ("host", host)] {
            if !v.is_empty() {
                res.insert(k.into(), Value::String(v.into()));
            }
        }
        let active = enabled && !url.is_empty() && !app_key.is_empty();
        let i = Arc::new(Inner {
            url: url.trim_end_matches('/').into(),
            key: app_key.into(),
            active,
            resource: Value::Object(res),
            q: Mutex::new(VecDeque::new()),
            cv: Condvar::new(),
            max_queue: 10_000,
            retries: 4,
            closed: AtomicBool::new(false),
            sent: AtomicU64::new(0),
            dropped: AtomicU64::new(0),
        });
        let worker = if active {
            let w = i.clone();
            Some(thread::spawn(move || loop_flush(w)))
        } else {
            None
        };
        Client { i, worker: Mutex::new(worker) }
    }

    pub fn from_env() -> Client {
        let on = matches!(env("RELAY_TELEM_ENABLED").trim().to_lowercase().as_str(), "1" | "true" | "yes" | "on");
        let mut host = env("RELAY_TELEM_HOST");
        if host.is_empty() {
            host = env("HOSTNAME");
        }
        Client::new(&env("RELAY_URL"), &env("RELAY_APP_KEY"), on, &host, &env("RELAY_TELEM_SERVICE"), &env("RELAY_TELEM_ENV"), &env("RELAY_TELEM_VERSION"))
    }

    pub fn sent(&self) -> u64 { self.i.sent.load(Ordering::Relaxed) }
    pub fn dropped(&self) -> u64 { self.i.dropped.load(Ordering::Relaxed) }

    fn push(&self, mut e: Value, tags: &[(&str, &str)]) {
        if !self.i.active || self.i.closed.load(Ordering::Relaxed) {
            return;
        }
        if !tags.is_empty() {
            let m: Map<String, Value> = tags.iter().map(|(k, v)| (k.to_string(), Value::String(v.to_string()))).collect();
            e["tags"] = Value::Object(m);
        }
        e["ts"] = Value::String(now_rfc3339());
        let mut q = self.i.q.lock().unwrap();
        if q.len() >= self.i.max_queue {
            q.pop_front();
            self.i.dropped.fetch_add(1, Ordering::Relaxed);
        }
        q.push_back(e);
        if q.len() >= 500 {
            self.i.cv.notify_one();
        }
    }

    pub fn counter(&self, name: &str, delta: f64, tags: &[(&str, &str)]) {
        self.push(json!({"kind":"metric","type":"counter","name":name,"value":delta}), tags);
    }
    pub fn gauge(&self, name: &str, value: f64, tags: &[(&str, &str)]) {
        self.push(json!({"kind":"metric","type":"gauge","name":name,"value":value}), tags);
    }
    pub fn histogram(&self, name: &str, value: f64, unit: &str, tags: &[(&str, &str)]) {
        self.push(json!({"kind":"metric","type":"histogram","name":name,"value":value,"unit":unit}), tags);
    }
    /// Records elapsed milliseconds as a histogram when the guard is dropped.
    pub fn timer(&self, name: &str, tags: &[(&str, &str)]) -> Timer<'_> {
        Timer { c: self, name: name.into(), tags: tags.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect(), t0: Instant::now() }
    }
    pub fn log(&self, level: &str, msg: &str, tags: &[(&str, &str)]) {
        self.push(json!({"kind":"log","level":level,"msg":msg}), tags);
    }
    pub fn event(&self, name: &str, msg: &str, tags: &[(&str, &str)]) {
        self.push(json!({"kind":"event","name":name,"msg":msg}), tags);
    }
    pub fn span(&self, name: &str, trace_id: &str, span_id: &str, parent_id: &str, ms: f64, failed: bool, tags: &[(&str, &str)]) {
        let mut e = json!({"kind":"span","name":name,"value":ms,"unit":"ms","trace_id":trace_id,"span_id":span_id,"status":if failed {"error"} else {"ok"}});
        if !parent_id.is_empty() {
            e["parent_id"] = Value::String(parent_id.into());
        }
        self.push(e, tags);
    }
    pub fn heartbeat(&self) {
        self.push(json!({"kind":"hb"}), &[]);
    }

    /// Send everything queued now (blocking).
    pub fn flush(&self) {
        flush(&self.i);
    }

    /// Flush and stop the background thread.
    pub fn close(&self) {
        if self.i.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        self.i.cv.notify_all();
        if let Some(h) = self.worker.lock().unwrap().take() {
            let _ = h.join();
        }
        flush(&self.i);
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        self.close();
    }
}

fn loop_flush(i: Arc<Inner>) {
    while !i.closed.load(Ordering::Relaxed) {
        {
            let g = i.q.lock().unwrap();
            let _ = i.cv.wait_timeout(g, Duration::from_secs(2)).unwrap();
        }
        flush(&i);
    }
}

fn flush(i: &Inner) {
    if !i.active {
        return;
    }
    loop {
        let batch: Vec<Value> = {
            let mut q = i.q.lock().unwrap();
            let n = q.len().min(1000);
            q.drain(..n).collect()
        };
        if batch.is_empty() {
            return;
        }
        let n = batch.len() as u64;
        if post(i, batch) { i.sent.fetch_add(n, Ordering::Relaxed); } else { i.dropped.fetch_add(n, Ordering::Relaxed); }
    }
}

fn post(i: &Inner, events: Vec<Value>) -> bool {
    let body = json!({"resource": i.resource, "events": events}).to_string();
    let mut gz = GzEncoder::new(Vec::new(), Compression::fast());
    if gz.write_all(body.as_bytes()).is_err() {
        return false;
    }
    let bytes = match gz.finish() { Ok(b) => b, Err(_) => return false };
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(5)).build();
    let url = format!("{}/ingest/v1/batch", i.url);
    let mut delay = 0.3f64;
    for attempt in 0..=i.retries {
        let mut wait = delay;
        let res = agent
            .post(&url)
            .set("Authorization", &format!("Bearer {}", i.key))
            .set("Content-Type", "application/json")
            .set("Content-Encoding", "gzip")
            .send_bytes(&bytes);
        match res {
            Ok(r) if r.status() == 200 || r.status() == 202 => return true,
            Ok(_) => {}
            Err(ureq::Error::Status(code, r)) => {
                if (400..500).contains(&code) && code != 429 {
                    return false; // retrying cannot help
                }
                if let Some(ra) = r.header("Retry-After").and_then(|v| v.parse::<f64>().ok()) {
                    if ra > 0.0 { wait = ra; }
                }
            }
            Err(_) => {}
        }
        if attempt < i.retries {
            let jitter = (SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().subsec_nanos() % 1000) as f64 / 1000.0;
            thread::sleep(Duration::from_secs_f64(wait + jitter * wait * 0.5));
            delay = (delay * 2.0).min(10.0);
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, BufRead, BufReader};
    use std::net::TcpListener;

    fn hub(codes: Vec<u16>) -> (u16, Arc<Mutex<(usize, usize)>>) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let got = Arc::new(Mutex::new((0usize, 0usize)));
        let g = got.clone();
        thread::spawn(move || {
            let mut codes = codes;
            for s in l.incoming() {
                let mut s = s.unwrap();
                let mut r = BufReader::new(s.try_clone().unwrap());
                let mut len = 0usize;
                loop {
                    let mut line = String::new();
                    r.read_line(&mut line).unwrap();
                    if line == "\r\n" || line.is_empty() { break; }
                    if let Some(v) = line.to_lowercase().strip_prefix("content-length: ") { len = v.trim().parse().unwrap(); }
                }
                let mut body = vec![0; len];
                r.read_exact(&mut body).unwrap();
                let code = if codes.is_empty() { 202 } else { codes.remove(0) };
                if code == 202 {
                    let mut dec = flate2::read::GzDecoder::new(&body[..]);
                    let mut txt = String::new();
                    dec.read_to_string(&mut txt).unwrap();
                    let v: Value = serde_json::from_str(&txt).unwrap();
                    let mut g = g.lock().unwrap();
                    g.0 += v["events"].as_array().unwrap().len();
                    g.1 += 1;
                }
                let extra = if code == 429 { "Retry-After: 0\r\n" } else { "" };
                write!(s, "HTTP/1.1 {} X\r\n{}Content-Length: 2\r\nConnection: close\r\n\r\n{{}}", code, extra).unwrap();
            }
        });
        (port, got)
    }

    #[test]
    fn batch_retry_and_drop() {
        let (p, got) = hub(vec![429]);
        let c = Client::new(&format!("http://127.0.0.1:{p}"), "rk_t", true, "h", "svc", "", "");
        for _ in 0..300 { c.counter("n", 1.0, &[("a", "b")]); }
        drop(c.timer("t", &[]));
        c.close();
        assert_eq!((c.sent(), c.dropped()), (301, 0));
        assert_eq!(got.lock().unwrap().0, 301);
        let (p2, _) = hub(vec![400]);
        let d = Client::new(&format!("http://127.0.0.1:{p2}"), "rk_t", true, "h", "", "", "");
        d.gauge("g", 1.0, &[]);
        d.close();
        assert_eq!((d.sent(), d.dropped()), (0, 1));
    }

    #[test]
    fn disabled_is_noop() {
        let c = Client::new("", "", false, "", "", "", "");
        c.gauge("g", 1.0, &[]);
        c.close();
        assert_eq!(c.sent(), 0);
    }
}
