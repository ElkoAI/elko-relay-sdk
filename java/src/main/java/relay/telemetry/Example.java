package relay.telemetry;

import java.util.Map;

/** RELAY_URL=... RELAY_APP_KEY=... RELAY_TELEM_ENABLED=1 java -cp out relay.telemetry.Example */
public class Example {
    public static void main(String[] a) throws Exception {
        RelayTelemetry t = RelayTelemetry.fromEnv();
        t.event("demo.started", "hello from Java", null);
        for (int i = 0; i < 20; i++) {
            try (var tm = t.timer("demo.work_ms", Map.of("step", "compute"))) { Thread.sleep(10 + i * 5); }
            t.counter("demo.iterations", 1, null);
            t.gauge("demo.progress", (i + 1) * 5.0, null);
        }
        t.log("info", "demo finished", null);
        t.heartbeat();
        t.close(); // flush on exit
        System.out.println("sent=" + t.sent() + " dropped=" + t.dropped());
    }
}
