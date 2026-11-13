#!/bin/bash
# Fuzz axum_dsl's action_text_html (sanitize.rb ACTION_TEXT_HTML_CALL, copied into src/main.rs) against Rails'
# ActionText::Content.new(html).to_html, run in the parity reference image. Usage: run.sh [seed] [count]
set -euo pipefail
cd "$(dirname "$0")"
python3 gen.py "${1:-1}" "${2:-1500}" > cases.jsonl
docker run --rm -i -e RAILS_ENV=production -e SECRET_KEY_BASE=x -v "$PWD":/f campfire-reference:latest bin/rails runner /f/rails.rb < cases.jsonl > rails.out
CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-/tmp/fuzz_ath_target} cargo build -q --release
"${CARGO_TARGET_DIR:-/tmp/fuzz_ath_target}/release/fuzz_ath" < cases.jsonl > rust.out
python3 cmp.py
