# syntax=docker/dockerfile:1
# The production image once-campfire-verification's bin/benchmark runs (bench/compare.rb): `make image` tags it
# once-campfire-axum-dsl:app (`bin/benchmark --apps axum-dsl`). The compiler is the sibling ../axum_dsl, passed as a named build context:
#
#   docker build --build-context axum_dsl=../axum_dsl -t once-campfire-axum-dsl:app .
#
# The harness runs it with --network host, sets HTTP_PORT, and mounts the seeded Rails storage at /rails/storage
# (db/production.sqlite3 and files/), so the defaults below point there.

# 1. Ruby: compile campfire.axum.rb to a Rust crate (no cargo here).
FROM ruby:4.0.7 AS emit
WORKDIR /src/axum_dsl
COPY --from=axum_dsl Gemfile Gemfile.lock ./
RUN bundle config set --local without "development test" && bundle install
COPY --from=axum_dsl exe exe
COPY --from=axum_dsl lib lib
WORKDIR /src/campfire_axum_dsl
COPY . .
RUN BUNDLE_GEMFILE=/src/axum_dsl/Gemfile bundle exec ruby /src/axum_dsl/exe/axum_dsl build campfire.axum.rb \
      -o /crate --emit-only

# 2. Rust: build the crate (the verification README pins Rust 1.98.1; rusqlite bundles SQLite).
FROM rust:1.98.1-bookworm AS build
WORKDIR /crate
COPY --from=emit /crate .
ENV CARGO_TARGET_DIR=/target
RUN cargo build --release

# 3. Runtime: the binary, run from the crate directory, because /assets is served from its public/.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=emit /crate/public public
COPY --from=build /target/release/campfire /app/campfire
ENV BIND=0.0.0.0 \
    DATABASE_PATH=/rails/storage/db/production.sqlite3 \
    ACTIVE_STORAGE_PATH=/rails/storage/files
# No USER: the server runs as root. The harness bind-mounts a db/ owned by whoever ran it (uid 1001 on a GitHub
# runner) and only chmods it after /up answers, but startup already writes the database (WAL, migrations table).
# PORT is what the generated main() reads, falling back to `set :port` (8099); the harness names it HTTP_PORT.
CMD ["sh", "-c", "if [ -n \"${HTTP_PORT:-}\" ] && [ -z \"${PORT:-}\" ]; then export PORT=\"$HTTP_PORT\"; fi; exec /app/campfire"]
