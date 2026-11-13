# Campfire in axum_dsl. The compiler is the sibling project ../axum_dsl; the hooks run `make -C campfire_axum_dsl <target>`.
#
#   dsl-check       parse and type-check campfire.axum.rb, no Rust
#   build           write the crate to /tmp/campfire_axum_dsl-out and cargo build it
#   crate-keep      build, then keep a copy of the generated crate to compare against
#   crate-diff      build, then diff the generated crate against the kept copy (a refactor leaves it identical)
#   emit-keep       emit the crate without cargo into $(OUT).emit-kept, to compare against
#   emit-diff       compile in memory (no cargo) and diff against the emit-keep copy: a summary by route/query, then a readable diff
#   schema-check    build, then prepare every query against db/migrate on an in-memory database (no server)
#   e2e-campfire    build, then drive the service over HTTP (needs curl and sqlite3)
#   e2e-parity      build, then diff each plain-GET parity state's server HTML against the Rails reference (needs node)
#   image           the production image once-campfire-verification's bin/benchmark runs (needs docker)

.PHONY: check-fast dsl-check build crate-keep crate-diff emit-keep emit-diff schema-check laws e2e-campfire e2e-parity image bench-local parity-up parity-sync parity-run parity-shard parity-shard-all parity-wait parity-cancel parity-status parity-logs parity-fetch parity-stop

# The dsl-check hook runs `make check-fast`.
check-fast: dsl-check

AXUM_DSL = ruby ../axum_dsl/exe/axum_dsl
# Sibling folders the exec-runner copies beside this project besides those named elsewhere in this file (it reads every ../NAME here).
RUNNER_SIBLINGS = ../once-campfire-rust
OUT = /tmp/campfire_axum_dsl-out

# Same as axum_dsl's Makefile: one cargo target dir outside the (possibly scratch) tree, shared with axum_dsl's own
# builds so axum and tokio compile once, and generated crates are warning-free.
export CARGO_TARGET_DIR := $(if $(AXUM_TARGET_DIR),$(AXUM_TARGET_DIR),/tmp/axum_dsl_target)
RUSTFLAGS ?= -Dwarnings
export RUSTFLAGS

# The compiler's notices that repeat on every build (N-VIEW-LOCALS, N-STR-STRIP-RUBY, about 100 lines) are counted in
# one line, not printed; N-DESTROY, which lists the statements a `destroy` runs, still is. `AXUM_DSL_NOTICE=all make
# <target>` prints them all.
AXUM_DSL_NOTICE ?= N-DESTROY
export AXUM_DSL_NOTICE

dsl-check:
	$(AXUM_DSL) campfire.axum.rb --check

build:
	$(AXUM_DSL) build campfire.axum.rb -o $(OUT)

# The generated crate before and after a change that should not move it (an action body moved into a model def):
# `crate-keep` on the tree before, `crate-diff` on the tree after. The diff is of the generated Rust, so it shows
# exactly what the change did to the app; no difference is said in one line. The source map (axum_dsl.map.json) is
# left out: it moves with every DSL line number.
crate-keep: build
	rm -rf $(OUT).kept && cp -R $(OUT) $(OUT).kept

crate-diff: build
	@diff -ru -x axum_dsl.map.json $(OUT).kept $(OUT) && echo "crate-diff: the generated crate is identical to the kept copy"

# The same comparison without cargo: `emit-keep` writes the crate (no cargo) and `emit-diff` compiles the tree in memory and
# compares it with that copy, naming each changed route or query and showing the changed piece of its handler. The command
# exits 1 when the crates differ; that is an answer, not an error, so only exit 2 (usage or a compile error) fails the target.
emit-keep:
	rm -rf $(OUT).emit-kept && $(AXUM_DSL) campfire.axum.rb -o $(OUT).emit-kept

emit-diff:
	@$(AXUM_DSL) emit-diff campfire.axum.rb --against $(OUT).emit-kept; rc=$$?; [ $$rc -le 1 ] || exit $$rc

# axum_dsl schema-check: the binary's --schema-check applies db/migrate to an in-memory database and prepares every query.
schema-check:
	$(AXUM_DSL) schema-check campfire.axum.rb -o $(OUT)

# The app's laws (test/laws/*.axum.rb) under cargo test, against a disposable database (test/laws/run.sh).
laws:
	bash test/laws/run.sh

# Port 8099 and its own out dir; test/e2e_campfire.sh builds its database from db/migrate and test/seed.sql.
e2e-campfire: build
	sh test/e2e_campfire.sh $(OUT)

# WAVE-PLAN Track CP: the server layer of once-campfire-rust's parity check, locally (test/parity_server.mjs). Port 8098;
# the seed is a copy of the VM's parity/.seed/default, the expected HTML the VM run's reference captures. STATES
# takes the harness's state-id globs, comma-separated (`*` stops at `/`, `**` does not); a hook passes it as its
# `states` parameter (RAJ_PARAM_STATES). Each run builds into its own directory and keeps a copy of its binary,
# because parallel runs (one per builder) share CARGO_TARGET_DIR, whose debug/campfire every build overwrites; a
# lock directory holds the build and the copy together.
STATES ?= $(or $(RAJ_PARAM_STATES),**)
# A projected hook runs in raj's scratch copy of the workspace, which lacks the gitignored inputs (the harness's
# node_modules), so its action names the saved projects folder, PARITY_WORKSPACE=..., and the read-only inputs --
# the harness, the seed, the reference captures -- come from there; the sources under test stay the scratch copy's.
ifdef PARITY_WORKSPACE
export PARITY_DIR = $(PARITY_WORKSPACE)/once-campfire-rust/parity
export PARITY_SEED = $(PARITY_WORKSPACE)/campfire_axum_dsl/test/parity-seed/.seed/default
export PARITY_REFERENCE = $(PARITY_WORKSPACE)/parity-results/out/compare-2026-10-22T16-46-09-695Z/reference
endif
PARITY_LOCK = /tmp/campfire_parity.lock
e2e-parity:
	@out=$$(mktemp -d /tmp/campfire_parity.XXXXXX); held=; \
	trap 'rm -rf "$$out"; [ -z "$$held" ] || rmdir $(PARITY_LOCK)' EXIT; \
	for i in $$(seq 1 600); do mkdir $(PARITY_LOCK) 2>/dev/null && held=1 && break; sleep 1; done; \
	[ -n "$$held" ] || { echo "FAIL: $(PARITY_LOCK) held for 10 minutes; remove it if no build is running"; exit 1; }; \
	$(AXUM_DSL) build campfire.axum.rb -o "$$out" && cp "$(CARGO_TARGET_DIR)/debug/campfire" "$$out/campfire.bin"; \
	built=$$?; rmdir $(PARITY_LOCK); held=; [ $$built = 0 ] || exit $$built; \
	PARITY_BIN="$$out/campfire.bin" node --experimental-strip-types test/parity_server.mjs "$$out" '$(STATES)'

# bench/compare.rb looks for once-campfire-<app>:app; with `--apps axum-dsl` that is this tag. The compiler is the
# sibling ../axum_dsl, passed as a named build context, so the build context stays this directory.
IMAGE ?= once-campfire-axum-dsl:app
image:
	docker build --build-context axum_dsl=../axum_dsl --build-context r2r_laws=../r2r-laws -t $(IMAGE) .

# WAVE-PLAN AP0: the release build on the verification repo's real seed, driven by its load generator with its
# route contracts (test/bench_local.rb). LABEL names the run; compare runs made on the same host only. The load
# generator builds in its own target dir and without -Dwarnings, as the verification repo builds it.
# ROUTES (comma-separated), DURATION (seconds), REPEAT (rounds) and DATA_DIRS (comma-separated NAME=DIR variants,
# the same binary on each) narrow or repeat a run; empty means the script's default.
# Every build is also kept as $(BENCH_BINS)/LABEL/ (the binary with copies of the crate's public/ and pwa/, which the
# server reads from its working directory), once: a label already saved is never replaced or deleted, so a baseline
# cannot change under a comparison; a new build needs a new LABEL. BASELINE=<label> then measures the fresh build
# (variant LABEL) against that earlier saved build (variant <label>), A/B as with DATA_DIRS: same seed copy, load and
# alternating order, only the binary differs. It is refused with DATA_DIRS (one thing varies at a time), when no build was saved under <label>,
# and when it equals LABEL (the run would measure the baseline against itself).
BENCH_OUT = /tmp/campfire_axum_dsl-bench
BENCH_BINS = /tmp/campfire_bench_bins
LABEL ?= run
BASELINE ?=
ROUTES ?=
DURATION ?=
REPEAT ?=
DATA_DIRS ?=
BENCH_ARGS = $(if $(ROUTES),--routes $(ROUTES)) $(if $(DURATION),--duration $(DURATION)) $(if $(REPEAT),--repeat $(REPEAT)) \
	$(foreach d,$(subst $(comma), ,$(DATA_DIRS)),--data-dir $(d)) \
	$(if $(BASELINE),--binary $(BASELINE)=$(BENCH_BINS)/$(BASELINE)/campfire)
comma := ,
bench-local:
	@if [ -n "$(BASELINE)" ]; then \
	  [ -z "$(DATA_DIRS)" ] || { echo "bench-local: BASELINE and DATA_DIRS vary one thing each; give only one"; exit 1; }; \
	  [ "$(BASELINE)" != "$(LABEL)" ] || { echo "bench-local: BASELINE equals LABEL ($(LABEL)); give the new build a label of its own"; exit 1; }; \
	  [ -x "$(BENCH_BINS)/$(BASELINE)/campfire" ] || { echo "bench-local: no saved binary for BASELINE=$(BASELINE) at $(BENCH_BINS)/$(BASELINE)/campfire; run make bench-local LABEL=$(BASELINE) first"; exit 1; }; \
	fi
	$(AXUM_DSL) build campfire.axum.rb -o $(BENCH_OUT) --release
	env -u CARGO_TARGET_DIR RUSTFLAGS= cargo build --release --locked --manifest-path ../once-campfire-verification/loadgen/Cargo.toml
	@if [ -z "$(LABEL)" ]; then echo "bench-local: LABEL is empty"; exit 1; fi
	@if [ -e "$(BENCH_BINS)/$(LABEL)" ]; then \
	  echo "bench-local: kept the build already saved as $(BENCH_BINS)/$(LABEL) (a saved build is never replaced); give a new LABEL to save this one"; \
	else \
	  mkdir -p "$(BENCH_BINS)/$(LABEL)" && \
	  cp "$(CARGO_TARGET_DIR)/release/campfire" "$(BENCH_BINS)/$(LABEL)/campfire" && \
	  cp -R "$(BENCH_OUT)/public" "$(BENCH_OUT)/pwa" "$(BENCH_BINS)/$(LABEL)/"; \
	fi
	ruby test/bench_local.rb $(BENCH_OUT) $(CARGO_TARGET_DIR)/release/campfire --label $(LABEL) $(BENCH_ARGS)

# VM parity helpers (Mac only; they need gcloud). Source test/parity_vm.sh, then call the pvm functions.
# shards run one state slice at a time because they share the harness ports 4111/4112.
PARITY_VM_SH := $(CURDIR)/test/parity_vm.sh
PARITY_SHARDS ?= $(or $(SHARDS),4)
PARITY_MATRIX ?= $(or $(MATRIX),full)
PARITY_WORKERS ?= $(or $(WORKERS),2)
PARITY_SHARD ?= $(or $(SHARD),0)
PARITY_STATES ?= $(or $(STATES),**)

parity-up:
	@bash -c 'source "$(PARITY_VM_SH)"; pvm-up'

parity-sync:
	@bash -c 'source "$(PARITY_VM_SH)"; pvm-sync'

parity-run:
	@bash -c 'source "$(PARITY_VM_SH)"; pvm-run "$(PARITY_STATES)" "$(PARITY_MATRIX)" "$(PARITY_WORKERS)"'

parity-shard:
	@bash -c 'source "$(PARITY_VM_SH)"; pvm-shard "$(PARITY_SHARD)" "$(PARITY_SHARDS)" "$(PARITY_MATRIX)" "$(PARITY_WORKERS)"'

parity-shard-all:
	@bash -c 'source "$(PARITY_VM_SH)"; pvm-shard-all "$(PARITY_SHARDS)" "$(PARITY_MATRIX)" "$(PARITY_WORKERS)"'

parity-wait:
	@bash -c 'source "$(PARITY_VM_SH)"; pvm-wait'

parity-cancel:
	@bash -c 'source "$(PARITY_VM_SH)"; pvm-cancel'

parity-status:
	@bash -c 'source "$(PARITY_VM_SH)"; pvm-status'

parity-logs:
	@bash -c 'source "$(PARITY_VM_SH)"; pvm-logs'

parity-fetch:
	@bash -c 'source "$(PARITY_VM_SH)"; pvm-fetch'

parity-stop:
	@bash -c 'source "$(PARITY_VM_SH)"; pvm-stop'
