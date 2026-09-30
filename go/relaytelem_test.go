package relaytelem

import (
	"compress/gzip"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestBatchesAndFlushOnClose(t *testing.T) {
	var got atomic.Int64
	var posts atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer rk_test" || r.URL.Path != "/ingest/v1/batch" {
			w.WriteHeader(401)
			return
		}
		zr, _ := gzip.NewReader(r.Body)
		b, _ := io.ReadAll(zr)
		var p struct {
			Resource map[string]any   `json:"resource"`
			Events   []map[string]any `json:"events"`
		}
		if err := json.Unmarshal(b, &p); err != nil {
			t.Error(err)
		}
		if p.Resource["service"] != "svc" {
			t.Errorf("resource %v", p.Resource)
		}
		got.Add(int64(len(p.Events)))
		posts.Add(1)
		w.WriteHeader(202)
	}))
	defer srv.Close()
	c := New(Options{URL: srv.URL, AppKey: "rk_test", Enabled: true, Service: "svc", FlushEvery: time.Hour})
	for i := 0; i < 250; i++ {
		c.Counter("n", 1, Tags{"a": "b"})
	}
	c.Timer("t", nil)()
	c.Log("info", "hi", nil)
	c.Close()
	if got.Load() != 252 || posts.Load() != 1 || c.Sent() != 252 {
		t.Fatalf("got=%d posts=%d sent=%d", got.Load(), posts.Load(), c.Sent())
	}
}

func TestRetryOn429ThenSuccess(t *testing.T) {
	var n atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if n.Add(1) == 1 {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(429)
			return
		}
		w.WriteHeader(202)
	}))
	defer srv.Close()
	c := New(Options{URL: srv.URL, AppKey: "rk_x", Enabled: true, FlushEvery: time.Hour})
	c.Gauge("g", 1, nil)
	c.Close()
	if n.Load() != 2 || c.Sent() != 1 {
		t.Fatalf("attempts=%d sent=%d", n.Load(), c.Sent())
	}
}

func TestDropsOnQueueFullAndDisabledNoop(t *testing.T) {
	c := New(Options{URL: "http://127.0.0.1:1", AppKey: "rk_x", Enabled: true, MaxQueue: 3, FlushEvery: time.Hour, FlushAt: 1 << 30, Retries: -1})
	for i := 0; i < 10; i++ {
		c.Gauge("g", 1, nil)
	}
	if c.Dropped() != 7 {
		t.Fatalf("dropped=%d", c.Dropped())
	}
	off := New(Options{})
	off.Gauge("g", 1, nil) // must not panic
	off.Close()
}

func Test4xxNotRetried(t *testing.T) {
	var n atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { n.Add(1); w.WriteHeader(400) }))
	defer srv.Close()
	c := New(Options{URL: srv.URL, AppKey: "rk_x", Enabled: true, FlushEvery: time.Hour})
	c.Gauge("g", 1, nil)
	c.Close()
	if n.Load() != 1 || c.Dropped() != 1 {
		t.Fatalf("n=%d dropped=%d", n.Load(), c.Dropped())
	}
}
