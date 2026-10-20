# campfire_axum_dsl

Basecamp's [Campfire](https://github.com/basecamp/once-campfire) written in
[`axum_dsl`](https://github.com/rajangdavis/axum_dsl), a Ruby DSL that compiles to a Rust axum server. The goal
is Campfire with **no Rust of the app's own** (`set :rust, :none`) that passes the
[once-campfire-verification](https://github.com/basecamp/once-campfire-verification) contracts. Where the DSL
cannot express something yet, the gap is logged in [GAPS.md](GAPS.md), which the next compiler waves work from.

## What it does

It reads and writes the SQLite schema Rails built, so a Rails database can be mounted as is.

- **Sessions:** sign in and out. `POST /session` is rate-limited per client address (20 a minute, then 429).
  Behind a proxy the key is the peer address unless the deployment forwards the client's
  (`use_layer :trace, forwarded: true`).
- **Rooms:** `GET /` sends you to your last room (the `last_room` cookie: plain, HttpOnly, SameSite=Lax, only
  the room id) while you are still a member, else to your first membership. A room page carries a strong
  `ETag` from its newest message id, so a matching `If-None-Match` is a bodiless 304.
- **Messages:** the earlier-messages page, and posting a message (the message, its Action Text body and its
  FTS row in one `transaction do ... end`).
- **Sidebar and search.**
- **Avatars:** the stored image a Rails `signed_id` token names, served from Active Storage's Disk service
  with a public cache and an `ETag`.
- **`/up`** and a fingerprinted stylesheet: `public/campfire.css` is served only as
  `/assets/campfire-<sha256 prefix>.css`, and `views/layout.html` writes that URL with
  `{{ asset_path "campfire.css" }}`.

## Run

The compiler is expected as the sibling checkout `../axum_dsl`.

```sh
make dsl-check      # parse and type-check campfire.axum.rb
make build          # write the crate to /tmp/campfire_axum_dsl-out and build it
make e2e-campfire   # build, then test/e2e_campfire.sh (needs curl, sqlite3 or python3, and ffprobe)
```

By hand: a fresh database from the schema and the seed, then the server on :8099.

```sh
sqlite3 /tmp/campfire.sqlite3 < db/migrate/001_schema.sql
sqlite3 /tmp/campfire.sqlite3 < test/seed.sql
cd /tmp/campfire_axum_dsl-out && SECRET_KEY_BASE=$(head -c 32 /dev/zero | tr '\0' x) \
  DATABASE_PATH=/tmp/campfire.sqlite3 /tmp/axum_dsl_target/debug/campfire
```

Every seed user's password is `campfire-test-pw`; david@37signals.com is the administrator. Run the server from
the crate directory, because `/assets` is served from the copied `public/`.

## Settings

| Variable | Meaning |
|----------|---------|
| `SECRET_KEY_BASE` | at least 32 bytes; signs the session cookie and the avatar `signed_id` token |
| `DATABASE_PATH` | the SQLite file (the benchmark mounts Rails' `/rails/storage/db/production.sqlite3`) |
| `ACTIVE_STORAGE_PATH` | the Disk service root, default `storage/files` (the benchmark mounts `/rails/storage/files`) |
| `PORT` | the listen port, default 8099; the image also accepts the harness's `HTTP_PORT` |

## Benchmark

`make image` builds `once-campfire-axum-dsl:app` from the [Dockerfile](Dockerfile) (the compiler is passed in
as the `axum_dsl` build context), which once-campfire-verification runs with `bin/benchmark --apps axum-dsl`.
The [Benchmark workflow](.github/workflows/benchmark.yml) does the same on a GitHub-hosted runner: run it from
the Actions tab, with `preflight` ticked for the contracts only. Hosted runners are shared VMs, so its
requests/sec are a smoke test, not numbers to compare with the reference results. For those,
[aws-benchmark.sh](aws-benchmark.sh) sets up a dedicated 16-core Linux host (written for an AWS c7a.4xlarge)
and runs Rails, Rust and this app with the report's settings.

The image runs as root: the harness mounts a database folder owned by whoever ran it, and the server writes
the database as it starts, before the harness opens up the folder's permissions.

## Layout

- `campfire.axum.rb`: the root service (server, port, settings, cookies, the static mount, the database and
  migrations), then the `use_dsl` lines that splice in the files below, in declaration order.
- `models/`: one file per model (`user`, `session`, `current`, `room`, `message`, `avatar`), each holding its
  records, queries and currents. `current.axum.rb` holds `current :user, required: :authenticate`.
- `controllers/`: one file per controller (`sessions`, `rooms`, `sidebars`, `searches`, `health`, `avatars`)
  holding the routes. `params.axum.rb` holds the params blocks, and `authenticate.axum.rb` the shared
  `before :authenticate` filter, which the public routes and `/assets` skip.
- `views/`: the layout, the pages and the message partials. `public/campfire.css`: the stylesheet.
- `db/migrate/001_schema.sql`: once-campfire's `db/schema.rb` as `IF NOT EXISTS` statements, FTS5 index
  included.
- `test/`: `seed.sql`, the avatar fixture, and `e2e_campfire.sh`, the HTTP check.
