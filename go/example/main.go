// go run ./example   (set RELAY_URL, RELAY_APP_KEY, RELAY_TELEM_ENABLED=1)
package main

import (
	"time"

	relaytelem "example.com/relay-telemetry/go"
)

func main() {
	t := relaytelem.FromEnv()
	defer t.Close() // flush on exit

	t.Event("demo.started", "hello from Go", nil)
	for i := 0; i < 20; i++ {
		done := t.Timer("demo.work_ms", relaytelem.Tags{"step": "compute"})
		time.Sleep(time.Duration(10+i*5) * time.Millisecond)
		done()
		t.Counter("demo.iterations", 1, nil)
		t.Gauge("demo.progress", float64(i+1)/20*100, nil)
	}
	t.Log("info", "demo finished", nil)
	t.Heartbeat()
}
