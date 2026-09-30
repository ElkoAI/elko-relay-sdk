#!/usr/bin/env bash
# Smoke test: RELAY_URL=https://relay.example.com RELAY_APP_KEY=rk_... ./smoke.sh
# Sends one of every kind and prints the HTTP status of each.
set -u
: "${RELAY_URL:?set RELAY_URL}"; : "${RELAY_APP_KEY:?set RELAY_APP_KEY}"
H=(-H "Authorization: Bearer $RELAY_APP_KEY")
u=${RELAY_URL%/}/ingest/v1
show() { printf '%-10s HTTP %s\n' "$1" "$2"; }
show hb      "$(curl -sS -o /dev/null -w '%{http_code}' "${H[@]}" -X POST "$u/hb" -d '{}')"
show log     "$(curl -sS -o /dev/null -w '%{http_code}' "${H[@]}" -X POST "$u/log" -H 'Content-Type: text/plain' --data-binary 'hello from curl smoke')"
show metric  "$(curl -sS -o /dev/null -w '%{http_code}' "${H[@]}" -X POST "$u/metric" -d '{"name":"smoke.count","type":"counter","value":1}')"
show event   "$(curl -sS -o /dev/null -w '%{http_code}' "${H[@]}" -X POST "$u/event" -d '{"name":"smoke.done","msg":"ok"}')"
show batch   "$(curl -sS -o /dev/null -w '%{http_code}' "${H[@]}" -X POST "$u/batch" -d '{"events":[{"kind":"metric","name":"smoke.g","type":"gauge","value":3},{"kind":"log","level":"info","msg":"batched"}]}')"
show statsd  "$(curl -sS -o /dev/null -w '%{http_code}' "${H[@]}" -X POST "$u/statsd" --data-binary $'smoke.s:1|c\nsmoke.t:12|ms')"
