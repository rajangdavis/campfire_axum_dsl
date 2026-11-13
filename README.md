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
- **First run:** an install with no users sends `/session/new` to `/first_run`, whose form creates the account,
  its administrator and the first room.
- **Rooms:** `GET /` sends you to your last room (the `last_room` cookie: plain and not HttpOnly, as Rails'
  `cookies.permanent[:last_room]`, holding only the room id) while you are still a member, else to your first
  membership. A room page carries a strong `ETag` from its newest message id, so a matching `If-None-Match` is a
  bodiless 304. Open, closed and direct rooms: creating, editing (an open room turned closed and back), deleting.
- **Messages:** the earlier-messages page, permalinks, posting (the message, its Action Text body and its FTS row
  in one `transaction do ... end`, the other members' unread marks with it), attachments, editing, deleting and
  boosts.
- **Sidebar and search** (recent searches and clearing them), mention autocomplete, involvement (notification
  level), link unfurling (`POST /unfurl_link`) and the Action Cable endpoint.
- **Account and people:** account settings (name, join code, logo removal, custom CSS, which the layout writes on
  every page), member roles and removal, the member list's lazy paging past 500 people, bans, avatars, the bots
  (create, edit, key reset, deactivate) and the bot message API, profiles, session transfer, joining by invite link,
  Web Push subscriptions, the PWA manifest and service worker.
- **Not reproduced:** Rails' background jobs (blob analysis, purges, Web Push delivery, bot webhooks); GAPS.md
  records each place they show.
- **Avatars:** the stored image a Rails `signed_id` token names, served from Active Storage's Disk service
  with a public cache and an `ETag`.
- **Active Storage:** representation and blob redirects, the Disk service downloads (with libvips variants), and
  direct uploads for a signed-in caller (the blob JSON with its signed upload URL, then the Disk service PUT).
- **`/up`** and a fingerprinted stylesheet: `public/campfire.css` is served only as
  `/assets/campfire-<sha256 prefix>.css`, and `views/layout.html` writes that URL with
  `{{ asset_path "campfire.css" }}`.

## Run

The compiler is expected as the sibling checkout `../axum_dsl`.

```sh
make dsl-check      # parse and type-check campfire.axum.rb
make build          # write the crate to /tmp/campfire_axum_dsl-out and build it
make e2e-campfire   # build, then test/e2e_campfire.sh (needs curl, sqlite3 or python3, and ffprobe)
make e2e-parity     # build, then diff each plain-GET parity state's HTML against a Rails reference run (needs node)
make bench-local    # release build on the verification repo's seed, under its load generator and route contracts
```

`test/write_routes.py` replays every form the pages render (from a parity run's Rails captures) against Rails and
this app on the parity seed and reports the routes this app is missing; it needs Docker and both images.
`test/differential/` replays scripted writes against a fresh Rails and a fresh build of this app, each on its own
copy of a parity seed, and compares the status and Location, every table row and the pages after (see its README);
its `fuzz_*` directories fuzz axum_dsl's Action Text sanitizer, image variants and upload identification against Rails.
`test/laws/run.sh` builds the crate and runs its laws (`AXUM_DSL_SEED=<u64>` explores other inputs).
`test/rails_tests/run.sh` runs Rails' own controller tests against this app through a proxy (175 of 185 pass; the
README there lists the rest). `test/parity_vm.sh` drives the full parity harness on a Google Cloud VM.

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
[bench-linux.sh](bench-linux.sh) sets up a dedicated Linux host or VM (its header has the Google Cloud commands)
and runs Rails, Rust and this app with the report's settings.

The image runs as root: the harness mounts a database folder owned by whoever ran it, and the server writes
the database as it starts, before the harness opens up the folder's permissions.

## Layout

- `campfire.axum.rb`: the root service (server, port, settings, cookies, the static mount, the database and
  migrations), then the `use_dsl` lines that splice in the files below, in declaration order.
- `models/`: one file per model (`account`, `active_storage`, `autocomplete`, `avatar`, `ban`, `bot`, `bot_api`,
  `current`, `first_run`, `membership`, `message`, `push`, `push_subscription`, `room`, `room_form`, `search`,
  `session`, `sidebar`, `user`, `variant`), each a `model do` holding its records and SQL queries; controllers hold
  none. `current.axum.rb` holds `current :user, required: :authenticate, reader: :current_user`.
- `controllers/`: one `controller do` per file, named after its path as Rails names them: `accounts` and `accounts/`
  (`bots`, `bots/keys`, `users`, `custom_styles`, `join_codes`, `logos`) have their own `before :ensure_can_administer`
  filters and defs (see axum_dsl's docs/controllers.md); the others (`active_storage`, `autocomplete`, `avatars`, `bot_messages`,
  `errors`, `first_runs`, `health`, `logos`, `messages`, `people`, `profiles`, `push_subscriptions`, `pwa`,
  `qr_code`, `room_forms`, `room_fragments`, `rooms`, `searches`, `sessions`, `sidebars`, `unfurl_links`, `users`)
  holding the routes; `params.axum.rb` (a fragment) holds the params blocks.
- `controllers/concerns/`: ApplicationController's shared filters: `authenticate` (`before :authenticate`, which
  the public routes and `/assets` skip), `banned_ips` (BlockBannedRequests) and `platform` (ApplicationPlatform);
  `authorization` holds the shared defs (`ensure_can_administer`, `account_flags`, `not_found`). The flash
  (`redirect(..., notice:/alert:)`, `take_flash`) is declared once in campfire.axum.rb.
- `test/laws/`: laws over the routes (`accounts.axum.rb`: who may reach each account page and write; `flash.axum.rb`:
  the session cookie's flash states and the sign-in redirect), compiled into
  the crate's `cargo test`; `test/laws/run.sh` runs them against a disposable database.
- `views/`: the layout, the pages, the partials and the Turbo Stream broadcasts. `public/`: the stylesheets,
  scripts, images and sounds, served fingerprinted under `/assets`.
- `db/migrate/001_schema.sql`: once-campfire's `db/schema.rb` as `IF NOT EXISTS` statements, FTS5 index
  included.
- `test/`: `seed.sql` and the avatar fixture; `e2e_campfire.sh`, the HTTP check; `parity_server.mjs`,
  `parity_scoreboard.mjs` and `parity_vm.sh`, the parity tools; `bench_local.rb`, the local benchmark;
  `cable_check.mjs` and `cable_broadcast_check.mjs`, the Action Cable checks; `write_routes.py`, the write-route
  replay; `differential/`, the scripted write comparison against Rails.
