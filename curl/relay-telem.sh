#!/usr/bin/env bash
# relay-telem.sh — tiny shell client for Elko Relay telemetry (needs curl only).
#
#   export RELAY_URL=https://relay.example.com RELAY_APP_KEY=rk_your_app_key RELAY_TELEM_ENABLED=1
#   . ./relay-telem.sh
#   relay_counter orders.placed 1 region=eu
#   relay_gauge   queue.depth 42
#   relay_histogram db.query_ms 12.5 table=orders
#   relay_log error "checkout failed"
#   relay_event deploy.finished "v1.2.3"
#   relay_hb
#
# Each call is one synchronous HTTP POST (fire-and-forget: errors are ignored,
# never fail your script). For many events, use relay_batch with NDJSON on stdin:
#   printf '%s\n' '{"kind":"metric","type":"counter","name":"n","value":1}' | relay_batch
# Direct CLI use:  ./relay-telem.sh counter orders.placed 1 region=eu

_relay_on() {
  case "$(printf %s "${RELAY_TELEM_ENABLED:-}" | tr '[:upper:]' '[:lower:]')" in 1|true|yes|on) ;; *) return 1 ;; esac
  [ -n "${RELAY_URL:-}" ] && [ -n "${RELAY_APP_KEY:-}" ]
}

_relay_esc() { # JSON string escape
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

_relay_tags() { # k=v ... -> ,"tags":{...}
  [ $# -eq 0 ] && return 0
  local out="" kv
  for kv in "$@"; do
    case "$kv" in *=*) out+="${out:+,}\"$(_relay_esc "${kv%%=*}")\":\"$(_relay_esc "${kv#*=}")\"" ;; esac
  done
  [ -n "$out" ] && printf ',"tags":{%s}' "$out"
  return 0
}

_relay_post() { # $1=path, stdin=body; $2=content-type
  _relay_on || return 0
  curl -sS -o /dev/null --max-time "${RELAY_TIMEOUT:-5}" --retry 2 --retry-delay 1 \
    -X POST "${RELAY_URL%/}$1" -H "Authorization: Bearer ${RELAY_APP_KEY}" \
    -H "Content-Type: ${2:-application/json}" --data-binary @- 2>/dev/null || true
}

_relay_res() {
  local r="" pair k var v
  for pair in service:RELAY_TELEM_SERVICE env:RELAY_TELEM_ENV version:RELAY_TELEM_VERSION host:RELAY_TELEM_HOST; do
    k=${pair%%:*}; var=${pair#*:}; v=${!var:-}
    [ -n "$v" ] && r+="${r:+,}\"$k\":\"$(_relay_esc "$v")\""
  done
  printf '{%s}' "$r"
}

_relay_one() { # $1=kind, rest=json fragment (no braces)
  printf '{"kind":"%s",%s}' "$1" "$2" | _relay_post "/ingest/v1/$1"
}

relay_counter()   { local n=$1 v=${2:-1}; shift $(($# > 1 ? 2 : 1)); _relay_one metric "\"type\":\"counter\",\"name\":\"$(_relay_esc "$n")\",\"value\":$v$(_relay_tags "$@")"; }
relay_gauge()     { local n=$1 v=$2; shift 2; _relay_one metric "\"type\":\"gauge\",\"name\":\"$(_relay_esc "$n")\",\"value\":$v$(_relay_tags "$@")"; }
relay_histogram() { local n=$1 v=$2; shift 2; _relay_one metric "\"type\":\"histogram\",\"name\":\"$(_relay_esc "$n")\",\"value\":$v$(_relay_tags "$@")"; }
relay_log()       { local l=$1 m=$2; shift 2; _relay_one log "\"level\":\"$(_relay_esc "$l")\",\"msg\":\"$(_relay_esc "$m")\"$(_relay_tags "$@")"; }
relay_event()     { local n=$1 m=${2:-}; shift $(($# > 1 ? 2 : 1)); _relay_one event "\"name\":\"$(_relay_esc "$n")\",\"msg\":\"$(_relay_esc "$m")\"$(_relay_tags "$@")"; }
relay_hb()        { printf '{}' | _relay_post /ingest/v1/hb; }

relay_batch() { # stdin: NDJSON events with "kind"; sent as a JSON batch (partial accept)
  local evs; evs=$(paste -sd, -)
  [ -n "$evs" ] && printf '{"resource":%s,"events":[%s]}' "$(_relay_res)" "$evs" | _relay_post /ingest/v1/batch
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then # CLI mode
  cmd=${1:-}; shift || true
  case "$cmd" in
    counter|gauge|histogram|log|event) "relay_$cmd" "$@" ;;
    hb) relay_hb ;;
    batch) relay_batch ;;
    *) echo "usage: $0 counter|gauge|histogram|log|event|hb|batch ..." >&2; exit 2 ;;
  esac
fi
