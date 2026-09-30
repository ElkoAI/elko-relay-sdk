"""python3 example.py   (RELAY_URL, RELAY_APP_KEY, RELAY_TELEM_ENABLED=1)"""
import time
from relay_telemetry import from_env

t = from_env()
t.event("demo.started", "hello from Python")
for i in range(20):
    with t.timer("demo.work_ms", step="compute"):
        time.sleep(0.01 + i * 0.005)
    t.counter("demo.iterations")
    t.gauge("demo.progress", (i + 1) / 20 * 100)
t.log("info", "demo finished")
t.heartbeat()
t.close()  # flush on exit (also automatic via atexit)
print("sent", t.sent, "dropped", t.dropped)
