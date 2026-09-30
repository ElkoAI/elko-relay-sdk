#!/usr/bin/env bash
# Fails if anything private leaks into this repo. Run from the repo root before publishing.
set -euo pipefail
cd "$(dirname "$0")/.."
bad=0
chk() { # description, regex
  local out
  out=$(grep -rIn -E --exclude-dir=node_modules --exclude-dir=target --exclude-dir=dist --exclude-dir=out \
        --exclude-dir=.git --exclude=check-public.sh --exclude=Cargo.lock -e "$2" . || true)
  if [ -n "$out" ]; then echo "LEAK ($1):"; echo "$out"; bad=1; fi
}
chk "private hostname"  'darkfabrik|elko\.ai|jsoprych|elko-relay|elkorelay'
chk "internal host name" '(^|[^A-Za-z])(think|mum)\.(local|lan|internal)'
chk "private IPv4"      '(^|[^0-9.])(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)'
chk "real-looking app key" 'rk_[A-Za-z0-9]{20,}'
chk "secret material"   '(BEGIN [A-Z ]*PRIVATE KEY|nsc_|eyJhbGciOi)'
if [ $bad -ne 0 ]; then echo "check-public: FAILED"; exit 1; fi
echo "check-public: ok"
