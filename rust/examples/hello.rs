// RELAY_URL=... RELAY_APP_KEY=... RELAY_TELEM_ENABLED=1 cargo run --example hello
fn main() {
    let t = relay_telemetry::Client::from_env();
    t.event("demo.started", "hello from Rust", &[]);
    for i in 0..20u64 {
        {
            let _t = t.timer("demo.work_ms", &[("step", "compute")]);
            std::thread::sleep(std::time::Duration::from_millis(10 + i * 5));
        }
        t.counter("demo.iterations", 1.0, &[]);
        t.gauge("demo.progress", (i + 1) as f64 * 5.0, &[]);
    }
    t.log("info", "demo finished", &[]);
    t.heartbeat();
    t.close(); // flush on exit (also on Drop)
    println!("sent={} dropped={}", t.sent(), t.dropped());
}
