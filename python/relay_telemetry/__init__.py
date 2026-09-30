"""Elko Relay telemetry client — stdlib only, Python 3.8+.

    from relay_telemetry import from_env
    t = from_env()                          # RELAY_URL, RELAY_APP_KEY, RELAY_TELEM_ENABLED=1
    t.counter("orders.placed", 1, region="eu")
    t.gauge("queue.depth", 42)
    with t.timer("db.query_ms", table="orders"):
        ...
    t.log("error", "checkout failed", order="o1")
    # flushes automatically at exit (atexit); or t.close()

Non-blocking: calls only append to a bounded in-memory deque. A daemon thread
POSTs gzip'd batches to /ingest/v1/batch with retry + backoff.
"""
from __future__ import annotations

import atexit
import collections
import gzip
import json
import os
import random
import socket
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any, Callable, Deque, Dict, List, Optional

__all__ = ["Client", "from_env"]


def _truthy(v: Optional[str]) -> bool:
    return (v or "").strip().lower() in ("1", "true", "yes", "on")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class _Timer:
    def __init__(self, c: "Client", name: str, tags: Dict[str, Any]):
        self.c, self.name, self.tags = c, name, tags

    def __enter__(self):
        self.t0 = time.perf_counter()
        return self

    def __exit__(self, *exc):
        self.c.histogram(self.name, (time.perf_counter() - self.t0) * 1000.0, "ms", **self.tags)
        return False


class Client:
    def __init__(
        self,
        url: str = "",
        app_key: str = "",
        enabled: bool = False,
        host: str = "",
        service: str = "",
        env: str = "",
        version: str = "",
        max_queue: int = 10000,
        flush_every: float = 2.0,
        flush_at: int = 500,
        retries: int = 4,
        timeout: float = 5.0,
        on_error: Optional[Callable[[Exception], None]] = None,
    ) -> None:
        self.url = url.rstrip("/")
        self.app_key = app_key
        self.enabled = enabled
        self.resource = {k: v for k, v in dict(service=service, env=env, version=version, host=host or socket.gethostname()).items() if v}
        self.flush_every, self.flush_at, self.retries, self.timeout = flush_every, flush_at, retries, timeout
        self.on_error = on_error
        self.dropped = 0
        self.sent = 0
        self._q: Deque[dict] = collections.deque(maxlen=max_queue)
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._closed = False
        self._thread: Optional[threading.Thread] = None
        if self._active:
            self._thread = threading.Thread(target=self._loop, name="relay-telemetry", daemon=True)
            self._thread.start()
            atexit.register(self.close)

    @property
    def _active(self) -> bool:
        return bool(self.enabled and self.url and self.app_key)

    # -- api -------------------------------------------------------------
    def _push(self, e: dict, tags: Dict[str, Any]) -> None:
        if not self._active or self._closed:
            return
        if tags:
            e["tags"] = tags
        e["ts"] = _now()
        with self._lock:
            if len(self._q) == self._q.maxlen:
                self.dropped += 1  # deque drops the oldest itself
            self._q.append(e)
            n = len(self._q)
        if n >= self.flush_at:
            self._wake.set()

    def counter(self, name: str, delta: float = 1, **tags: Any) -> None:
        self._push({"kind": "metric", "type": "counter", "name": name, "value": delta}, tags)

    def gauge(self, name: str, value: float, **tags: Any) -> None:
        self._push({"kind": "metric", "type": "gauge", "name": name, "value": value}, tags)

    def histogram(self, name: str, value: float, unit: str = "", **tags: Any) -> None:
        self._push({"kind": "metric", "type": "histogram", "name": name, "value": value, "unit": unit}, tags)

    def timer(self, name: str, **tags: Any) -> _Timer:
        """Context manager recording elapsed milliseconds as a histogram."""
        return _Timer(self, name, tags)

    def log(self, level: str, msg: str, **tags: Any) -> None:
        self._push({"kind": "log", "level": level, "msg": msg}, tags)

    def event(self, name: str, msg: str = "", **tags: Any) -> None:
        self._push({"kind": "event", "name": name, "msg": msg}, tags)

    def span(self, name: str, trace_id: str, span_id: str, ms: float, failed: bool = False,
             parent_id: str = "", **tags: Any) -> None:
        e = {"kind": "span", "name": name, "value": ms, "unit": "ms", "trace_id": trace_id,
             "span_id": span_id, "status": "error" if failed else "ok"}
        if parent_id:
            e["parent_id"] = parent_id
        self._push(e, tags)

    def heartbeat(self) -> None:
        self._push({"kind": "hb"}, {})

    # -- flushing --------------------------------------------------------
    def flush(self) -> None:
        if not self._active:
            return
        while True:
            with self._lock:
                batch: List[dict] = [self._q.popleft() for _ in range(min(1000, len(self._q)))]
            if not batch:
                return
            if self._post(batch):
                self.sent += len(batch)
            else:
                self.dropped += len(batch)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._stop.set()
        self._wake.set()
        if self._thread and self._thread is not threading.current_thread():
            self._thread.join(timeout=self.timeout * (self.retries + 2))
        self.flush()

    def _loop(self) -> None:
        while not self._stop.is_set():
            self._wake.wait(self.flush_every)
            self._wake.clear()
            self.flush()

    def _post(self, batch: List[dict]) -> bool:
        body = gzip.compress(json.dumps({"resource": self.resource, "events": batch}).encode())
        delay = 0.3
        for attempt in range(self.retries + 1):
            wait = delay
            req = urllib.request.Request(
                self.url + "/ingest/v1/batch", data=body, method="POST",
                headers={"Authorization": "Bearer " + self.app_key, "Content-Type": "application/json",
                         "Content-Encoding": "gzip"},
            )
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as r:
                    r.read()
                    if r.status in (200, 202):
                        return True
            except urllib.error.HTTPError as e:
                if e.code == 429 or e.code >= 500:
                    ra = e.headers.get("Retry-After")
                    if ra and ra.isdigit() and int(ra) > 0:
                        wait = float(ra)
                else:  # 4xx: retrying cannot help
                    if self.on_error:
                        self.on_error(e)
                    return False
            except Exception as e:  # network error / timeout
                if attempt == self.retries and self.on_error:
                    self.on_error(e)
            if attempt < self.retries:
                time.sleep(wait + random.random() * wait * 0.5)
                delay = min(delay * 2, 10.0)
        return False


def from_env() -> Client:
    e = os.environ
    return Client(
        url=e.get("RELAY_URL", ""), app_key=e.get("RELAY_APP_KEY", ""),
        enabled=_truthy(e.get("RELAY_TELEM_ENABLED")), host=e.get("RELAY_TELEM_HOST", ""),
        service=e.get("RELAY_TELEM_SERVICE", ""), env=e.get("RELAY_TELEM_ENV", ""),
        version=e.get("RELAY_TELEM_VERSION", ""),
    )
