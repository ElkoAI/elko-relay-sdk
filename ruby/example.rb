# ruby -Ilib example.rb   (RELAY_URL, RELAY_APP_KEY, RELAY_TELEM_ENABLED=1)
require "relay_telemetry"

t = RelayTelemetry.from_env
t.event("demo.started", "hello from Ruby")
20.times do |i|
  t.timer("demo.work_ms", step: "compute") { sleep(0.01 + i * 0.005) }
  t.counter("demo.iterations")
  t.gauge("demo.progress", (i + 1) * 5.0)
end
t.log(:info, "demo finished")
t.heartbeat
t.close # flush on exit (also automatic via at_exit)
puts "sent=#{t.sent} dropped=#{t.dropped}"
