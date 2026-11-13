#!/bin/bash
# Campfire's laws (test/laws/*.axum.rb, included by campfire.axum.rb): `axum_dsl test` builds the crate and runs them
# with cargo test, against a disposable database made from the schema, test/seed.sql and test/laws/setup.sql.
#   test/laws/run.sh            AXUM_DSL_SEED=<u64> test/laws/run.sh explores other inputs
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Without the sqlite3 command-line tool (the raj-dev image has none), python3's sqlite3 module stands in for
# `sqlite3 DB <FILE`, as in test/e2e_campfire.sh.
if ! command -v sqlite3 >/dev/null; then
  sqlite3() { python3 -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.executescript(sys.stdin.read()); c.commit()' "$1"; }
fi
for f in db/migrate/*.sql test/seed.sql test/laws/setup.sql; do sqlite3 "$work/campfire.sqlite3" < "$f"; done
mkdir -p "$work/files"
export DATABASE_PATH="$work/campfire.sqlite3" ACTIVE_STORAGE_PATH="$work/files"
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-laws-secret-key-base-that-is-at-least-32-bytes-long}"
export RATE_LIMIT=0 FRONT=0 CAMPFIRE_RESPONSE_CACHE_MB=0
exec ruby ../axum_dsl/exe/axum_dsl test campfire.axum.rb -o "${LAWS_OUT:-/tmp/campfire_axum_dsl-laws}"
