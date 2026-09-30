import { fromEnv } from "./relay-telemetry";

async function main() {
  const t = fromEnv();
  t.event("demo.started", "hello from TypeScript");
  for (let i = 0; i < 20; i++) {
    const done = t.timer("demo.work_ms", { step: "compute" });
    await new Promise((r) => setTimeout(r, 10 + i * 5));
    done();
    t.counter("demo.iterations");
    t.gauge("demo.progress", ((i + 1) / 20) * 100);
  }
  t.log("info", "demo finished");
  t.heartbeat();
  await t.close(); // flush on exit
  console.log(`sent=${t.sent} dropped=${t.dropped}`);
}
main();
