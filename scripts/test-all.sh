#!/usr/bin/env bash
# Runs each language's tests where a toolchain exists. Skips (loudly) otherwise.
cd "$(dirname "$0")/.."
run() { local n=$1 t=$2; shift 2
  if ! command -v "$t" >/dev/null; then echo "SKIP $n ($t not installed)"; return; fi
  echo "== $n"; ( "$@" ) && echo "PASS $n" || { echo "FAIL $n"; fail=1; }; }
fail=0
run go go       bash -c 'cd go && go vet ./... && go test ./...'
run python python3 bash -c 'cd python && python3 -m unittest discover -s tests'
run ruby ruby   ruby ruby/test/client_test.rb
run rust cargo  bash -c 'cd rust && cargo test'
run typescript npx bash -c 'cd typescript && npm install --silent && npx tsc -p .'
run java javac  bash -c 'cd java && rm -rf out && javac --release 11 -d out src/main/java/relay/telemetry/*.java'
run php php     bash -c 'cd php && php -l src/Client.php'
run dotnet dotnet bash -c 'cd dotnet && dotnet build'
run curl bash   bash -n curl/relay-telem.sh
exit $fail
