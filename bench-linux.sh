#!/bin/sh
# Comparable benchmark numbers on a dedicated Linux host: Rails, Rust and this app (axum-dsl) under
# once-campfire-verification's bin/benchmark, with the published report's settings (docs/performance-review.md,
# "Reproduce"): 3 rounds, 8-second samples, 16 clients, four server cores and four load-generator cores, the
# normal route set and then the mixed profile. The GitHub workflow is a smoke test; this is the real run.
#
# Any Linux host or VM with Ubuntu 24.04, about 10 full cores free, 32 GB of RAM and 60 GB of disk. CPUS and
# CLIENT_CPUS name the cores for the app and for the load generator; keep them on different physical cores, so
# turn simultaneous multithreading off where the host allows it. On Google Cloud (15 full AMD Zen 4 cores):
#
#   gcloud compute instances create campfire-bench --zone=us-central1-a \
#     --machine-type=c3d-standard-30 --threads-per-core=1 \
#     --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
#     --boot-disk-size=60GB --boot-disk-type=pd-balanced
#   gcloud compute ssh campfire-bench --zone=us-central1-a
#   curl -fsSLO https://raw.githubusercontent.com/rajangdavis/campfire_axum_dsl/main/bench-linux.sh
#   CPUS=6-9 CLIENT_CPUS=10-13 sh bench-linux.sh      # inside tmux, so a dropped ssh does not end it
#   gcloud compute scp campfire-bench:bench/results.tar.gz . --zone=us-central1-a
#   gcloud compute instances delete campfire-bench --zone=us-central1-a
#
# It is safe to rerun: clones, the seed and images that exist are kept. Results land in
# $WORK/once-campfire-verification/tmp/bench/results/ and are packed into $WORK/results.tar.gz.
set -eu

WORK=${WORK:-$HOME/bench}
VERIFY_REPO=${VERIFY_REPO:-https://github.com/rajangdavis/once-campfire-verification.git}
APPS=${APPS:-rails,rust,axum-dsl}
CPUS=${CPUS:-8-11}
CLIENT_CPUS=${CLIENT_CPUS:-12-15}
RAILS_REV=90b330024dec3e757c79b6a7e6568f93da8e3148
RUST_TOOLCHAIN=1.98.1

highest=$(echo "$CPUS,$CLIENT_CPUS" | tr ',-' '\n\n' | sort -n | tail -1)
[ "$highest" -lt "$(nproc)" ] || { echo "bench-linux: --cpus $CPUS --client-cpus $CLIENT_CPUS needs CPU $highest, but this host has $(nproc) (0-$(($(nproc) - 1))); set CPUS and CLIENT_CPUS" >&2; exit 1; }

# 1. Prerequisites: the verification repo's own CI list, plus Docker with BuildKit (the Dockerfile uses
#    --build-context) and the headers the load generator builds against.
if ! command -v docker >/dev/null || ! command -v ruby >/dev/null; then
	sudo apt-get update
	sudo apt-get install -y --no-install-recommends docker.io docker-buildx ruby sqlite3 ffmpeg util-linux \
		git build-essential pkg-config libssl-dev curl ca-certificates
fi
if ! docker info >/dev/null 2>&1; then
	sudo usermod -aG docker "$USER"
	exec sg docker -c "sh '$0'"
fi
if ! command -v rustup >/dev/null && [ ! -x "$HOME/.cargo/bin/rustup" ]; then
	curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain "$RUST_TOOLCHAIN"
fi
PATH="$HOME/.cargo/bin:$PATH"
rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal

# 2. The layout compare.rb expects: the verification repo and the apps' sources side by side.
mkdir -p "$WORK"
cd "$WORK"
clone() { [ -d "$2/.git" ] || git clone "$1" "$2"; }
clone "$VERIFY_REPO" once-campfire-verification
clone https://github.com/rajangdavis/axum_dsl.git axum_dsl
clone https://github.com/rajangdavis/campfire_axum_dsl.git campfire_axum_dsl
ln -sfn campfire_axum_dsl once-campfire-axum-dsl
clone https://github.com/basecamp/once-campfire.git once-campfire
git -C once-campfire checkout --detach "$RAILS_REV"
clone https://github.com/basecamp/once-campfire-rust.git once-campfire-rust
git -C once-campfire-rust submodule update --init
rustup override set "$RUST_TOOLCHAIN" --path once-campfire-verification

# 3. The seed (which builds the pinned Rails image), the three app images and the load generator.
cd once-campfire-verification
[ -d fixtures/default ] || bin/seed
docker tag "once-campfire-verification:reference-$(echo "$RAILS_REV" | cut -c1-7)" once-campfire:app
docker build -t campfire-rust:app ../once-campfire-rust
make -C ../campfire_axum_dsl image
cargo build --release --locked --manifest-path loadgen/Cargo.toml

# 4. The two runs, as the report reproduces them.
export RAILS_BENCH_ENV='{"WEB_CONCURRENCY":"4","RAILS_MAX_THREADS":"1","RAILS_MIN_THREADS":"1"}'
bin/benchmark --apps "$APPS" --rounds 3 --duration 8 --concurrencies 16 \
	--cpus "$CPUS" --client-cpus "$CLIENT_CPUS" \
	--routes room_show,messages_page,sidebar,search,post_message
bin/benchmark --apps "$APPS" --rounds 3 --duration 8 --concurrencies 16 \
	--cpus "$CPUS" --client-cpus "$CLIENT_CPUS" --mixed-write-rate 10 \
	--routes room_show,messages_page,sidebar,search

tar -czf "$WORK/results.tar.gz" -C tmp/bench results
echo "bench-linux: done; copy $WORK/results.tar.gz back, then terminate the instance"
