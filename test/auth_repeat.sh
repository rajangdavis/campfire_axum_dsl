#!/usr/bin/env bash
# Repeat the two parked auth states in one cell, so a flaky pass/error rate is measured instead of guessed.
# Run on the parity VM after `pvm-sync` and with the candidate image built:
#
#   bash ~/bench/campfire_axum_dsl/test/auth_repeat.sh [RUNS] [STATES] [ENGINE] [VIEWPORT] [SCHEME] [WORKERS]
#
# It runs `parity/bin/candidate compare` sequentially; each run gets its own /tmp/parity-auth-<n> output.
# A run may exit 1 (a fail or error); that is recorded and the next run continues.
set -u

runs=${1:-5}
states=${2:-auth/sign_in/error,auth/sign_in/rate_limited}
engine=${3:-chromium}
viewport=${4:-desktop}
scheme=${5:-light}
workers=${6:-1}
root=${PARITY_ROOT:-$HOME/bench/once-campfire-rust}
outroot=${PARITY_OUT_ROOT:-/tmp/parity-auth-repeat}
summary="$outroot/summary.txt"

mkdir -p "$outroot"
: >"$summary"
echo "runs=$runs states=$states cell=$engine/$viewport/$scheme workers=$workers" | tee -a "$summary"

cd "$root" || exit 1
for i in $(seq 1 "$runs"); do
  out="$outroot/run-$i"
  rm -rf "$out"
  log="$outroot/run-$i.log"
  echo "--- run $i/$runs -> $out" | tee -a "$summary"
  sg docker -c "PARITY_CANDIDATE_IMAGE=campfire-candidate-axum parity/bin/candidate compare --seed default --only '$states' --engines '$engine' --viewports '$viewport' --schemes '$scheme' --breakpoints exclude --workers '$workers' --out '$out'" 2>&1 | tee "$log"
  report="$out/report.json"
  if [ -f "$report" ]; then
    node -e '
      const fs = require("fs");
      const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const c = (r.info && r.info.counts) || r.counts || {};
      const line = `run=${process.argv[2]} pass=${c.pass ?? 0} fail=${c.fail ?? 0} error=${c.error ?? 0}`;
      console.log(line);
      fs.appendFileSync(process.argv[3], line + "\n");
    ' "$report" "$i" "$summary"
  else
    echo "run=$i report missing" | tee -a "$summary"
  fi
done

echo "--- summary ($summary)" | tee -a "$summary"
cat "$summary"
