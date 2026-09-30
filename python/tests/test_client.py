import gzip, json, threading, unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from relay_telemetry import Client


def serve(codes):
    got = {"events": 0, "posts": 0}

    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            assert self.headers["Authorization"] == "Bearer rk_t"
            code = codes.pop(0) if codes else 202
            if code == 202:
                p = json.loads(gzip.decompress(body))
                got["events"] += len(p["events"]); got["posts"] += 1
            self.send_response(code)
            if code == 429:
                self.send_header("Retry-After", "0")
            self.end_headers(); self.wfile.write(b"{}")
        def log_message(self, *a): pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, got


class T(unittest.TestCase):
    def test_batch_and_close(self):
        srv, got = serve([])
        c = Client(url=f"http://127.0.0.1:{srv.server_port}", app_key="rk_t", enabled=True, flush_every=3600)
        for _ in range(300): c.counter("n", 1, a="b")
        with c.timer("t"): pass
        c.close()
        self.assertEqual((got["events"], got["posts"], c.sent), (301, 1, 301))
        srv.shutdown()

    def test_retry_429(self):
        srv, got = serve([429])
        c = Client(url=f"http://127.0.0.1:{srv.server_port}", app_key="rk_t", enabled=True, flush_every=3600)
        c.gauge("g", 1); c.close()
        self.assertEqual((got["events"], c.sent, c.dropped), (1, 1, 0))
        srv.shutdown()

    def test_400_dropped_not_retried(self):
        srv, got = serve([400])
        c = Client(url=f"http://127.0.0.1:{srv.server_port}", app_key="rk_t", enabled=True, flush_every=3600)
        c.gauge("g", 1); c.close()
        self.assertEqual((c.sent, c.dropped), (0, 1))
        srv.shutdown()

    def test_queue_bound_and_disabled(self):
        c = Client(url="http://127.0.0.1:1", app_key="rk_t", enabled=True, max_queue=3, flush_every=3600, flush_at=10**9, retries=0)
        for _ in range(10): c.gauge("g", 1)
        self.assertEqual(c.dropped, 7)
        Client().gauge("g", 1)  # disabled: no-op


if __name__ == "__main__":
    unittest.main()
