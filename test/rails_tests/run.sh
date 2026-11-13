#!/bin/bash
# Run Rails' own controller tests (the reference's test/controllers, 185 tests) against the port. The tests run in the
# parity reference image; their requests go through port_proxy.rb to the port, which serves the tests' database file.
# Usage: run.sh [test paths under test/, default controllers] ; PORT, RUN_DIR, CANDIDATE_BIN override.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REF=${REFERENCE_DIR:-$HERE/../../../once-campfire-rust/reference}
D=${RUN_DIR:-/tmp/campfire-rails-tests} PORT=${PORT:-4601}
BIN=${CANDIDATE_BIN:-${CARGO_TARGET_DIR:-/tmp/axum_dsl_target}/debug/campfire} CRATE=${CANDIDATE_CRATE:-/tmp/campfire_axum_dsl-out}
TESTS=${*:-controllers}
fuser -k $PORT/tcp 2>/dev/null || true
rm -rf "$D" && mkdir -p "$D/db" "$D/tmp"
# The reference's tests, with test_helper.rb renamed and this directory's helper and proxy beside it.
cp -r "$REF/test" "$D/test" && mv "$D/test/test_helper.rb" "$D/test/test_helper_rails.rb"
cp "$HERE/test_helper.rb" "$HERE/port_proxy.rb" "$D/test/" && chmod -R 777 "$D"
rails() {
  docker run --rm --user root --network host -e RAILS_ENV=test -e PORT_URL="http://127.0.0.1:$PORT" -e PARALLEL_WORKERS=1 -e PROXY_LOG=${PROXY_LOG:-} -e CABLE_LOG=/rails/tmp/cable.log \
    -v "$D/test":/rails/test \
    -v "$D/db":/rails/storage/db -v "$D/tmp":/rails/tmp --entrypoint sh campfire-reference:app -c "cd /rails && $1"
}
# The schema, and the secret the test environment signs cookies with (tmp/local_secret.txt, kept for the run).
rails "bin/rails db:prepare >/dev/null && bin/rails runner 'File.write(\"tmp/secret\", Rails.application.secret_key_base)'"
(cd "$CRATE" && PORT=$PORT DATABASE_PATH="$D/db/test.sqlite3" ACTIVE_STORAGE_PATH="$D/tmp/storage" \
  AXUM_DSL_CABLE_LOG="$D/tmp/cable.log" SECRET_KEY_BASE="$(cat "$D/tmp/secret")" RATE_LIMIT=0 FRONT=0 CAMPFIRE_RESPONSE_CACHE_MB=0 \
  setsid nohup "$BIN" > "$D/port.log" 2>&1 &)
for i in $(seq 100); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/up" && break; sleep 0.1; done
# Paths are under test/; an option (-n NAME) and its value pass through as they are.
paths=$(for t in $TESTS; do case $t in -*|test_*|/*) printf ' %s' "$t" ;; *) printf ' test/%s' "$t" ;; esac; done)
rails "bin/rails test $paths -v" | tee "$D/tests.log" | grep -E "^[A-Za-z:]+Test#test_.* = [0-9.]+ s = [.FES]$|runs, " || true
fuser -k $PORT/tcp 2>/dev/null || true
