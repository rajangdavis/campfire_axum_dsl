# Campfire in axum_dsl. The compiler is the sibling project ../axum_dsl; the hooks run `make -C campfire_axum_dsl <target>`.
#
#   dsl-check       parse and type-check campfire.axum.rb, no Rust
#   build           write the crate to /tmp/campfire_axum_dsl-out and cargo build it
#   e2e-campfire    build, then drive the service over HTTP (needs curl and sqlite3)
#   e2e-parity      build, then diff each plain-GET parity state's server HTML against the Rails reference (needs node)
#   image           the production image once-campfire-verification's bin/benchmark runs (needs docker)

.PHONY: check-fast dsl-check build e2e-campfire e2e-parity image bench-local parity-up parity-sync parity-run parity-shard parity-shard-all parity-wait parity-cancel parity-status parity-logs parity-fetch parity-stop

# The dsl-check hook runs `make check-fast`.
check-fast: dsl-check

AXUM_DSL = ruby ../axum_dsl/exe/axum_dsl
OUT = /tmp/campfire_axum_dsl-out

# Same as axum_dsl's Makefile: one cargo target dir outside the (possibly scratch) tree, shared with axum_dsl's own
# builds so axum and tokio compile once, and generated crates are warning-free.
export CARGO_TARGET_DIR := $(if $(AXUM_TARGET_DIR),$(AXUM_TARGET_DIR),/tmp/axum_dsl_target)
RUSTFLAGS ?= -Dwarnings
export RUSTFLAGS

dsl-check:
	$(AXUM_DSL) campfire.axum.rb --check

build:
	$(AXUM_DSL) build campfire.axum.rb -o $(OUT)

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
	docker build --build-context axum_dsl=../axum_dsl -t $(IMAGE) .

# WAVE-PLAN AP0: the release build on the verification repo's real seed, driven by its load generator with its
# route contracts (test/bench_local.rb). LABEL names the run; compare runs made on the same host only. The load
# generator builds in its own target dir and without -Dwarnings, as the verification repo builds it.
BENCH_OUT = /tmp/campfire_axum_dsl-bench
LABEL ?= run
bench-local:
	$(AXUM_DSL) build campfire.axum.rb -o $(BENCH_OUT) --release
	env -u CARGO_TARGET_DIR RUSTFLAGS= cargo build --release --locked --manifest-path ../once-campfire-verification/loadgen/Cargo.toml
	ruby test/bench_local.rb $(BENCH_OUT) $(CARGO_TARGET_DIR)/release/campfire --label $(LABEL)

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
