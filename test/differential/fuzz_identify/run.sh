#!/bin/bash
# Fuzz axum_dsl's upload identification and analysis (multipart.rb: axum_dsl_identify_content_type, axum_dsl_upload_metadata)
# against Active Storage: Marcel::MimeType.for(first 4 KB, name:, declared_type:) and ImageAnalyzer::Vips's width and height,
# computed in the parity reference image (gen.rb). The port side is app.axum.rb, built with axum_dsl, answering each upload's
# content type and metadata. Usage: run.sh [seed] [count]
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD DSL=${AXUM_DSL:-$HERE/../../../../axum_dsl} OUT=${OUT:-/tmp/fuzz_identify-out} PORT=${PORT:-4791}
rm -rf run && mkdir -p run && chmod 777 run
docker run --rm --user root --entrypoint sh -e SEED="${1:-1}" -e N="${2:-1500}" -v "$HERE/run":/work -v "$HERE/gen.rb":/gen.rb \
  campfire-reference:app -c 'cd /rails && bundle exec ruby /gen.rb'
rm -rf "$OUT" && (cd "$DSL" && ruby -Ilib exe/axum_dsl build "$HERE/app.axum.rb" -o "$OUT" --emit-only)
(cd "$OUT" && CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-/tmp/axum_dsl_target} cargo build -q --locked)
fuser -k $PORT/tcp 2>/dev/null || true
(cd "$OUT" && PORT=$PORT setsid nohup "${CARGO_TARGET_DIR:-/tmp/axum_dsl_target}/debug/idfuzz" > "$HERE/run/app.log" 2>&1 &)
for i in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
python3 compare.py run $PORT
fuser -k $PORT/tcp 2>/dev/null || true
