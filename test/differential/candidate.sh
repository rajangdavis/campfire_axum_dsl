#!/bin/bash
# candidate.sh SEED PORT: run the built app (make build) on a fresh copy of the parity seed SEED; with CANDIDATE_DOCKER=1,
# the app's image (make image) instead.
HERE=$(cd "$(dirname "$0")" && pwd)
SEED=$1 PORT=$2 P=${PARITY_DIR:-$HERE/../../../once-campfire-rust/parity}
BIN=${CANDIDATE_BIN:-${CARGO_TARGET_DIR:-/tmp/axum_dsl_target}/debug/campfire} CRATE=${CANDIDATE_CRATE:-/tmp/campfire_axum_dsl-out}
fuser -k $PORT/tcp 2>/dev/null; sleep 0.3
D=${CANDIDATE_DATA:-/tmp/campfire-differential}-$PORT; rm -rf $D; mkdir -p $D; cp -r $P/.seed/$SEED/db $D/db; cp -r $P/.seed/$SEED/storage $D/files
set -a; . $P/.env.reference; set +a
if [ -n "${CANDIDATE_DOCKER:-}" ]; then
  # The app's image (make image), whose runtime libraries are the reference's (libvips for image_variant).
  docker rm -f campfire-differential-$PORT >/dev/null 2>&1
  docker run -d --name campfire-differential-$PORT --network host --env-file $P/.env.reference -e PORT=$PORT \
    -e DATABASE_PATH=$D/db/production.sqlite3 -e ACTIVE_STORAGE_PATH=$D/files -v $D:$D ${CANDIDATE_IMAGE:-once-campfire-axum-dsl:app} >/dev/null
else
  cd "$CRATE" && PORT=$PORT DATABASE_PATH=$D/db/production.sqlite3 ACTIVE_STORAGE_PATH=$D/files \
    setsid nohup "$BIN" >$D/log 2>&1 &
fi
for i in $(seq 50); do curl -sf -o /dev/null http://127.0.0.1:$PORT/up && exit 0; sleep 0.1; done; echo "candidate did not start"; tail $D/log; exit 1
