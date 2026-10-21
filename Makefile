# Campfire in axum_dsl. The compiler is the sibling project ../axum_dsl; the hooks run `make -C campfire_axum_dsl <target>`.
#
#   dsl-check       parse and type-check campfire.axum.rb, no Rust
#   build           write the crate to /tmp/campfire_axum_dsl-out and cargo build it
#   e2e-campfire    build, then drive the service over HTTP (needs curl and sqlite3)
#   image           the production image once-campfire-verification's bin/benchmark runs (needs docker)

.PHONY: check-fast dsl-check build e2e-campfire image bench-local

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
