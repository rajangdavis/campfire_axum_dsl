# shellcheck shell=bash
# The GCP VM that runs once-campfire-rust's full parity harness against our image (WAVE-PLAN Track CP): pixels and
# the states that need a browser, which `make e2e-parity` cannot check locally. Run from your Mac, where gcloud is
# logged in; raj's hooks run in raj-dev, which has no cloud access.
#
# Source this from your shell:  source ~/Desktop/projects/campfire_axum_dsl/test/parity_vm.sh
#
#   pvm-up              create the VM if it is missing, else start it; a fresh VM is provisioned in the background
#                       (Docker, the harness, the Rails reference image and the seed): follow it with pvm-status
#   pvm-sync            copy axum_dsl and campfire_axum_dsl over, rebuild our image and the candidate layer
#   pvm-run [GLOBS] [lean|full|desktop-light] [WORKERS]
#                       start the comparison in the background; GLOBS are the harness's comma-separated state-id
#                       globs (* stops at /, ** does not), default all. `desktop-light` (the default) is the initial
#                       Chromium/desktop/light cell; `lean` is the support matrix's lean set (every state on
#                       Chromium desktop+phone light/dark, smoke states on Firefox/WebKit, breakpoints); `full` is
#                       every engine, viewport, scheme and breakpoint sweep. WORKERS defaults to 2.
#   pvm-run-lean [GLOBS]  shorthand for `pvm-run GLOBS lean`
#   pvm-shard [SHARD] [SHARDS] [MATRIX] [WORKERS]
#                       run one state-id slice of a matrix, selected from screens.yml by index; full matrix
#                       remains the final gate, shards give earlier reports and can be rerun alone
#   pvm-shard-all [SHARDS] [MATRIX] [WORKERS]
#                       run every shard in order, wait for each, and pvm-fetch its report
#   pvm-wait             wait for the current tmux comparison to exit
#   pvm-cancel           kill the current comparison and its 4111/4112 servers, without stopping the VM
#   pvm-logs             follow ~/parity.log on the VM
#   pvm-verify [GLOBS] [ENGINES] [VIEWPORTS] [SCHEMES] [WORKERS]
#                       one targeted cell after a scoreboard run; default Chromium/desktop/light,
#                       2 workers, breakpoint sweep excluded; run pvm-sync first if source changed
#   pvm-ssh [ARGS]     open an interactive SSH session on the VM; pass `--command '…'` for one command
#   pvm-status          the VM's state, and the tail of the setup or comparison log
#   pvm-fetch           copy the newest report into parity-results/out/, with its scoreboard.md (failing layers and
#                       causes clustered across states: test/parity_scoreboard.mjs; needs node)
#   pvm-stop            stop the VM; the disk and the built images stay, so the next pvm-up is quick
#
# Override CAMPFIRE_PROJECTS, PARITY_VM, PARITY_PROJECT or PARITY_ZONE if they differ.

CAMPFIRE_PROJECTS="${CAMPFIRE_PROJECTS:-$HOME/Desktop/projects}"
PARITY_VM="${PARITY_VM:-campfire-parity}"
PARITY_PROJECT="${PARITY_PROJECT:-campfire-bench-2}"
PARITY_ZONE="${PARITY_ZONE:-us-east4-c}"

_pvm_gc() { gcloud --project "$PARITY_PROJECT" "$@"; }
_pvm_ssh() { _pvm_gc compute ssh "ubuntu@$PARITY_VM" --zone "$PARITY_ZONE" --command "$1"; }
_pvm_state() { _pvm_gc compute instances describe "$PARITY_VM" --zone "$PARITY_ZONE" --format='value(status)' 2>/dev/null || echo MISSING; }
_pvm_ready() { _pvm_ssh 'test -f ~/.parity-ready' 2>/dev/null; }

# pvm-ssh [gcloud ssh args] — open the VM interactively, or pass --command '...' for one command.
pvm-ssh() {
  _pvm_gc compute ssh "ubuntu@$PARITY_VM" --zone "$PARITY_ZONE" "$@"
}

pvm-up() {
  case "$(_pvm_state)" in
    MISSING)
      # The machine type most likely to have capacity first; 8 vCPUs is plenty for Playwright and two servers.
      local type
      for type in n2-standard-8 e2-standard-8 n2d-standard-8; do
        _pvm_gc compute instances create "$PARITY_VM" --zone "$PARITY_ZONE" --machine-type "$type" \
          --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
          --boot-disk-size 80GB --boot-disk-type pd-balanced >/dev/null && { echo "pvm: created $PARITY_VM ($type)"; break; }
      done
      [ "$(_pvm_state)" != MISSING ] || { echo "pvm: no machine type had capacity in $PARITY_ZONE; set PARITY_ZONE"; return 1; }
      ;;
    TERMINATED | STOPPED | SUSPENDED) _pvm_gc compute instances start "$PARITY_VM" --zone "$PARITY_ZONE" >/dev/null && echo "pvm: started $PARITY_VM" ;;
    *) echo "pvm: $PARITY_VM is $(_pvm_state)" ;;
  esac
  local i
  for i in $(seq 1 30); do _pvm_ssh true >/dev/null 2>&1 && break; sleep 5; done
  _pvm_ssh true >/dev/null 2>&1 || { echo "pvm: $PARITY_VM does not answer ssh"; return 1; }
  if _pvm_ready; then
    echo "pvm: $PARITY_VM is ready"
    return 0
  fi
  # What a fresh VM needs before its first comparison, run once in tmux; ~/.parity-ready marks the end.
  printf '%s\n' 'set -e' \
    'sudo apt-get update -q && sudo apt-get install -yq docker.io docker-buildx git make tmux' \
    'sudo usermod -aG docker ubuntu' \
    'mkdir -p ~/bench' \
    '[ -d ~/bench/once-campfire-rust ] || git clone --recurse-submodules https://github.com/basecamp/once-campfire-rust.git ~/bench/once-campfire-rust' \
    'cd ~/bench/once-campfire-rust' \
    'sg docker -c "parity/bin/reference build && parity/bin/seed build default"' \
    'touch ~/.parity-ready' |
    _pvm_ssh 'cat > ~/provision.sh && (tmux has-session -t setup 2>/dev/null || tmux new -d -s setup "bash ~/provision.sh 2>&1 | tee ~/setup.log")'
  echo "pvm: provisioning in the background (the reference image and the seed take a while); follow it with pvm-status"
}

pvm-sync() {
  _pvm_ready || { echo "pvm: $PARITY_VM is not provisioned yet; run pvm-up and wait for pvm-status to say ready"; return 1; }
  local tarball; tarball=$(mktemp "${TMPDIR:-/tmp}/parity-sync.XXXXXX")
  COPYFILE_DISABLE=1 tar -C "$CAMPFIRE_PROJECTS" --exclude='*/target' --exclude='campfire_axum_dsl/test/parity-seed' \
    --exclude='campfire_axum_dsl/test/parity-out' -czf "$tarball" axum_dsl campfire_axum_dsl &&
    _pvm_gc compute scp "$tarball" "ubuntu@$PARITY_VM:sync.tgz" --zone "$PARITY_ZONE" >/dev/null
  local rc=$?
  rm -f "$tarball"
  [ $rc = 0 ] || return $rc
  # The image build's output goes to a log; on failure its tail is shown.
  _pvm_ssh 'set -e; cd ~/bench && rm -rf axum_dsl campfire_axum_dsl && tar -xzf ~/sync.tgz 2>/dev/null
    cd once-campfire-rust
    sg docker -c "make -C ../campfire_axum_dsl image" >~/image.log 2>&1 || { tail -n 40 ~/image.log; exit 1; }
    sg docker -c "docker build -q -t campfire-candidate-axum --build-arg BASE_IMAGE=once-campfire-axum-dsl:app parity/docker/candidate"' &&
    echo "pvm: synced; the candidate image is rebuilt"
}

pvm-run() {
  local states="${1:-**}" matrix="${2:-desktop-light}" workers="${3:-2}" only="" flags=""
  _pvm_ssh 'tmux has-session -t parity 2>/dev/null' && { echo "pvm: a comparison is already running; see pvm-status"; return 1; }
  [ "$states" = "**" ] || only="--only \"$states\""
  case "$matrix" in
    lean | full) flags="--matrix $matrix" ;;
    desktop-light) flags="--engines chromium --viewports desktop --schemes light --breakpoints exclude" ;;
    *) echo "pvm: matrix must be lean, full or desktop-light (got $matrix)"; return 2 ;;
  esac
  # The command goes over as a file, so the globs reach the harness unexpanded.
  printf '%s\n' "cd ~/bench/once-campfire-rust && sg docker -c 'PARITY_CANDIDATE_IMAGE=campfire-candidate-axum parity/bin/candidate compare --seed default $flags --workers $workers $only' 2>&1 | tee ~/parity.log" |
    _pvm_ssh 'cat > ~/run.sh && tmux new -d -s parity "bash ~/run.sh"' &&
    echo "pvm: comparison started (states: $states, matrix: $matrix, workers: $workers); follow it with pvm-status"
}

pvm-run-lean() {
  pvm-run "${1:-**}" lean
}

# pvm-shard [SHARD] [SHARDS] [MATRIX] [WORKERS]
# Partition state ids from screens.yml by index and run one slice. This uses --only with exact
# state ids, so the slice is independent of shell glob expansion. Full matrix remains the final
# gate; shards give earlier reports and let a failing group be rerun alone.
pvm-shard() {
  local shard="${1:?pvm-shard needs SHARD}" count="${2:?pvm-shard needs SHARDS}" matrix="${3:-full}" workers="${4:-2}" states screens
  screens="${CAMPFIRE_PROJECTS}/once-campfire-rust/parity/screens.yml"
  if [ -f "$screens" ]; then
    states=$(awk -v s="$shard" -v n="$count" '/^- id:[[:space:]]*/ { id=$0; sub(/^- id:[[:space:]]*/, "", id); i++; if ((i - 1) % n == s) print id }' "$screens" | paste -sd, -)
  else
    # The VM has grep/sed/awk; node is intentionally not required there.
    states=$(_pvm_ssh "grep -E '^- id:' ~/bench/once-campfire-rust/parity/screens.yml | sed -E 's/^- id:[[:space:]]*//' | awk -v s=$shard -v n=$count '(NR - 1) % n == s' | paste -sd, -")
  fi
  [ -n "$states" ] || { echo "pvm: shard $shard/$count selected no states"; return 1; }
  pvm-run "$states" "$matrix" "$workers"
}

# Wait for the current tmux comparison to exit.
pvm-wait() {
  while _pvm_ssh 'tmux has-session -t parity 2>/dev/null'; do sleep 5; done
}

# pvm-shard-all [SHARDS] [MATRIX] [WORKERS]
# Run every shard in order, waiting and fetching each report. This does not run shards in
# parallel: they share ports 4111/4112.
pvm-shard-all() {
  local count="${1:-4}" matrix="${2:-full}" workers="${3:-2}" i
  for i in $(seq 0 $((count - 1))); do
    pvm-shard "$i" "$count" "$matrix" "$workers" || return 1
    pvm-wait
    pvm-fetch
  done
}

# Follow the current comparison log on the Mac.
pvm-logs() {
  _pvm_ssh 'tail -n 200 -f ~/parity.log'
}

# Stop the current comparison and its two servers, without stopping the VM.
pvm-cancel() {
  _pvm_ssh 'tmux kill-session -t parity 2>/dev/null || true'
  _pvm_ssh 'cd ~/bench/once-campfire-rust && parity/bin/candidate down --port 4112 >/dev/null 2>&1 || true; parity/bin/reference down --port 4111 >/dev/null 2>&1 || true'
}

# pvm-verify [GLOBS] [ENGINES] [VIEWPORTS] [SCHEMES] [WORKERS]
# One targeted cell after a lean/scoreboard run: default Chromium/desktop/light, 2 workers, breakpoint
# sweep excluded. Run pvm-sync first when app source changed; this only starts the comparison.
pvm-verify() {
  local states="${1:-**}" engines="${2:-chromium}" viewports="${3:-desktop}" schemes="${4:-light}" workers="${5:-2}" only=""
  _pvm_ssh 'tmux has-session -t parity 2>/dev/null' && { echo "pvm: a comparison is already running; see pvm-status"; return 1; }
  [ "$states" = "**" ] || only="--only \"$states\""
  printf '%s\n' "cd ~/bench/once-campfire-rust && sg docker -c 'PARITY_CANDIDATE_IMAGE=campfire-candidate-axum parity/bin/candidate compare --seed default --engines $engines --viewports $viewports --schemes $schemes --breakpoints exclude --workers $workers $only' 2>&1 | tee ~/parity.log" |
    _pvm_ssh 'cat > ~/run.sh && tmux new -d -s parity "bash ~/run.sh"' &&
    echo "pvm: verification started (states: $states, $engines/$viewports/$schemes, workers: $workers); follow it with pvm-status"
}

pvm-status() {
  local state; state=$(_pvm_state)
  echo "pvm: $PARITY_VM is $state"
  [ "$state" = RUNNING ] || return 0
  _pvm_ssh 'if [ ! -f ~/.parity-ready ]; then echo "provisioning:"; tail -n 5 ~/setup.log 2>/dev/null
    elif tmux has-session -t parity 2>/dev/null; then echo "comparison running:"; tail -n 3 ~/parity.log
    else echo "idle; last comparison:"; tail -n 2 ~/parity.log 2>/dev/null; fi'
}

pvm-fetch() {
  local run name tarball
  run=$(_pvm_ssh 'ls -1d ~/bench/once-campfire-rust/parity/out/compare-* 2>/dev/null | tail -n 1')
  [ -n "$run" ] || { echo "pvm: no comparison output on $PARITY_VM"; return 1; }
  name=$(basename "$run")
  tarball=$(mktemp "${TMPDIR:-/tmp}/parity-fetch.XXXXXX")
  _pvm_ssh "tar -czf ~/fetch.tgz -C ~/bench/once-campfire-rust/parity out/$name" &&
    _pvm_gc compute scp "ubuntu@$PARITY_VM:fetch.tgz" "$tarball" --zone "$PARITY_ZONE" >/dev/null &&
    mkdir -p "$CAMPFIRE_PROJECTS/parity-results" && tar -xzf "$tarball" -C "$CAMPFIRE_PROJECTS/parity-results" &&
    echo "pvm: fetched parity-results/out/$name" &&
    { ! command -v node >/dev/null || node "$CAMPFIRE_PROJECTS/campfire_axum_dsl/test/parity_scoreboard.mjs" \
        "$CAMPFIRE_PROJECTS/parity-results/out/$name" >"$CAMPFIRE_PROJECTS/parity-results/out/$name/scoreboard.md" &&
      echo "pvm: scoreboard in parity-results/out/$name/scoreboard.md"; }
  local rc=$?
  rm -f "$tarball"
  return $rc
}

pvm-stop() { _pvm_gc compute instances stop "$PARITY_VM" --zone "$PARITY_ZONE" >/dev/null && echo "pvm: stopped $PARITY_VM"; }
