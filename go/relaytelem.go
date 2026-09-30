// Package relaytelem is a tiny, dependency-free Elko Relay telemetry client.
//
// Non-blocking (bounded in-memory queue), batching (one POST per flush),
// retrying (exponential backoff + jitter, honours Retry-After), and safe to
// leave in production: when disabled, every call is a no-op.
//
//	t := relaytelem.FromEnv()
//	defer t.Close()                       // flushes on exit
//	t.Counter("orders.placed", 1, relaytelem.Tags{"region": "eu"})
//	t.Gauge("queue.depth", 42, nil)
//	done := t.Timer("db.query_ms", nil); defer done()
//	t.Log("error", "checkout failed", relaytelem.Tags{"order": "o1"})
//
// Env: RELAY_URL, RELAY_APP_KEY, RELAY_TELEM_ENABLED=1, RELAY_TELEM_HOST,
// RELAY_TELEM_SERVICE, RELAY_TELEM_ENV, RELAY_TELEM_VERSION.
package relaytelem

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Tags are low-cardinality dimensions (≤8 per metric; values ≤64 chars).
// Never put user ids, request ids or URLs with ids in tags.
type Tags map[string]any

// Options configures a Client. Zero values pick safe defaults.
type Options struct {
	URL, AppKey string
	Enabled     bool
	Host        string
	Service     string
	Env         string
	Version     string
	MaxQueue    int           // default 10000; oldest events are dropped when full
	FlushEvery  time.Duration // default 2s
	FlushAt     int           // flush early at this many events (default 500)
	Retries     int           // default 4
	Timeout     time.Duration // per request (default 5s)
	HTTP        *http.Client
	OnError     func(error) // optional; called on dropped batches
}

// Client batches events in the background.
type Client struct {
	o       Options
	mu      sync.Mutex
	q       []map[string]any
	wake    chan struct{}
	stop    chan struct{}
	done    chan struct{}
	dropped atomic.Int64
	sent    atomic.Int64
	closed  atomic.Bool
}

func truthy(s string) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// FromEnv builds a client from RELAY_* environment variables.
func FromEnv() *Client {
	h, _ := os.Hostname()
	if v := os.Getenv("RELAY_TELEM_HOST"); v != "" {
		h = v
	}
	return New(Options{
		URL: os.Getenv("RELAY_URL"), AppKey: os.Getenv("RELAY_APP_KEY"),
		Enabled: truthy(os.Getenv("RELAY_TELEM_ENABLED")),
		Host:    h, Service: os.Getenv("RELAY_TELEM_SERVICE"),
		Env: os.Getenv("RELAY_TELEM_ENV"), Version: os.Getenv("RELAY_TELEM_VERSION"),
	})
}

// New builds a client and starts the flusher when enabled.
func New(o Options) *Client {
	if o.MaxQueue <= 0 {
		o.MaxQueue = 10000
	}
	if o.FlushEvery <= 0 {
		o.FlushEvery = 2 * time.Second
	}
	if o.FlushAt <= 0 {
		o.FlushAt = 500
	}
	if o.Retries < 0 {
		o.Retries = 0
	} else if o.Retries == 0 {
		o.Retries = 4
	}
	if o.Timeout <= 0 {
		o.Timeout = 5 * time.Second
	}
	if o.HTTP == nil {
		o.HTTP = &http.Client{Timeout: o.Timeout}
	}
	o.URL = strings.TrimRight(o.URL, "/")
	c := &Client{o: o, wake: make(chan struct{}, 1), stop: make(chan struct{}), done: make(chan struct{})}
	if !c.active() {
		close(c.done)
		return c
	}
	go c.loop()
	return c
}

func (c *Client) active() bool { return c.o.Enabled && c.o.URL != "" && c.o.AppKey != "" }

func (c *Client) push(e map[string]any) {
	if c == nil || !c.active() || c.closed.Load() {
		return
	}
	e["ts"] = time.Now().UTC().Format(time.RFC3339Nano)
	c.mu.Lock()
	if len(c.q) >= c.o.MaxQueue {
		c.q = c.q[1:] // drop oldest: telemetry must never grow without bound
		c.dropped.Add(1)
	}
	c.q = append(c.q, e)
	n := len(c.q)
	c.mu.Unlock()
	if n >= c.o.FlushAt {
		select {
		case c.wake <- struct{}{}:
		default:
		}
	}
}

// Counter adds delta (≥0) to a monotonically increasing count.
func (c *Client) Counter(name string, delta float64, tags Tags) {
	c.push(map[string]any{"kind": "metric", "type": "counter", "name": name, "value": delta, "tags": tags})
}

// Gauge records a point-in-time value (queue depth, temperature, balance).
func (c *Client) Gauge(name string, v float64, tags Tags) {
	c.push(map[string]any{"kind": "metric", "type": "gauge", "name": name, "value": v, "tags": tags})
}

// Histogram records one observation (latency, size); the hub reports p50/p95/p99.
func (c *Client) Histogram(name string, v float64, unit string, tags Tags) {
	c.push(map[string]any{"kind": "metric", "type": "histogram", "name": name, "value": v, "unit": unit, "tags": tags})
}

// Timer returns a func that records the elapsed milliseconds when called.
func (c *Client) Timer(name string, tags Tags) func() {
	t0 := time.Now()
	return func() { c.Histogram(name, float64(time.Since(t0).Microseconds())/1000, "ms", tags) }
}

// Log sends a log line. level: debug|info|warn|error.
func (c *Client) Log(level, msg string, tags Tags) {
	c.push(map[string]any{"kind": "log", "level": level, "msg": msg, "tags": tags})
}

// Event records a discrete business/ops event ("deploy.finished").
func (c *Client) Event(name, msg string, tags Tags) {
	c.push(map[string]any{"kind": "event", "name": name, "msg": msg, "tags": tags})
}

// Span records a finished unit of work (traces-lite). ids are lowercase hex.
func (c *Client) Span(name, traceID, spanID, parentID string, d time.Duration, failed bool, tags Tags) {
	st := "ok"
	if failed {
		st = "error"
	}
	e := map[string]any{"kind": "span", "name": name, "value": float64(d.Microseconds()) / 1000, "unit": "ms",
		"trace_id": traceID, "span_id": spanID, "status": st, "tags": tags}
	if parentID != "" {
		e["parent_id"] = parentID
	}
	c.push(e)
}

// Heartbeat marks the app alive (drives Stopped/Recovered alerts).
func (c *Client) Heartbeat() { c.push(map[string]any{"kind": "hb"}) }

// Dropped is the number of events discarded (queue full or batch permanently failed).
func (c *Client) Dropped() int64 { return c.dropped.Load() }

// Sent is the number of events the hub accepted.
func (c *Client) Sent() int64 { return c.sent.Load() }

// Flush sends everything queued now and waits for the result.
func (c *Client) Flush() {
	if c == nil || !c.active() {
		return
	}
	c.drain()
}

// Close flushes and stops the background goroutine. Safe to call twice.
func (c *Client) Close() {
	if c == nil || !c.closed.CompareAndSwap(false, true) {
		return
	}
	if c.active() {
		close(c.stop)
		<-c.done
	}
}

func (c *Client) loop() {
	defer close(c.done)
	tk := time.NewTicker(c.o.FlushEvery)
	defer tk.Stop()
	for {
		select {
		case <-tk.C:
			c.drain()
		case <-c.wake:
			c.drain()
		case <-c.stop:
			c.drain()
			return
		}
	}
}

func (c *Client) resource() map[string]any {
	r := map[string]any{}
	for k, v := range map[string]string{"service": c.o.Service, "env": c.o.Env, "version": c.o.Version, "host": c.o.Host} {
		if v != "" {
			r[k] = v
		}
	}
	return r
}

func (c *Client) drain() {
	for {
		c.mu.Lock()
		n := len(c.q)
		if n > 1000 {
			n = 1000
		}
		batch := c.q[:n:n]
		c.q = c.q[n:]
		c.mu.Unlock()
		if len(batch) == 0 {
			return
		}
		if !c.post(batch) {
			c.dropped.Add(int64(len(batch)))
		} else {
			c.sent.Add(int64(len(batch)))
		}
	}
}

// post sends one batch with retries. Returns false when the batch is given up on.
func (c *Client) post(batch []map[string]any) bool {
	body, _ := json.Marshal(map[string]any{"resource": c.resource(), "events": batch})
	var zb bytes.Buffer
	zw := gzip.NewWriter(&zb)
	_, _ = zw.Write(body)
	_ = zw.Close()
	delay := 300 * time.Millisecond
	for attempt := 0; attempt <= c.o.Retries; attempt++ {
		req, _ := http.NewRequest("POST", c.o.URL+"/ingest/v1/batch", bytes.NewReader(zb.Bytes()))
		req.Header.Set("Authorization", "Bearer "+c.o.AppKey)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Content-Encoding", "gzip")
		res, err := c.o.HTTP.Do(req)
		wait := delay
		if err == nil {
			_, _ = io.Copy(io.Discard, res.Body)
			_ = res.Body.Close()
			switch {
			case res.StatusCode == 202 || res.StatusCode == 200:
				return true
			case res.StatusCode == 429 || res.StatusCode >= 500:
				if s, e := strconv.Atoi(res.Header.Get("Retry-After")); e == nil && s > 0 {
					wait = time.Duration(s) * time.Second
				}
			default: // 4xx: the batch itself is bad; retrying cannot help
				if c.o.OnError != nil {
					c.o.OnError(&httpError{res.StatusCode})
				}
				return false
			}
		} else if c.o.OnError != nil && attempt == c.o.Retries {
			c.o.OnError(err)
		}
		if attempt < c.o.Retries {
			time.Sleep(wait + time.Duration(rand.Int63n(int64(wait/2)+1)))
			if delay < 10*time.Second {
				delay *= 2
			}
		}
	}
	return false
}

type httpError struct{ code int }

func (e *httpError) Error() string { return "relaytelem: hub returned HTTP " + strconv.Itoa(e.code) }
