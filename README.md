# campfire_axum_dsl

Basecamp's Campfire (once-campfire) written in [`axum_dsl`](https://github.com/rajangdavis/axum_dsl) (checked out as the sibling `../axum_dsl`): a Ruby DSL file that compiles to a Rust
axum server. The goal is Campfire with **no Rust of the app's own** (`set :rust, :none`), passing the
once-campfire-verification contracts. Where the DSL cannot say something, the gap is logged in [GAPS.md](GAPS.md);
that list is what the next compiler waves work from.

This is C1, C2 and the C3 app polish: sign in and out, a room page (a strong `ETag` and the `last_room`
cookie), the earlier-messages page, the sidebar, search, `/up`, a fingerprinted stylesheet, a rate-limited
login, posting a message (one `transaction do ... end` for the message, its Action Text body and its FTS
row), and the stored avatar a Rails `signed_id` token names (served from Active Storage's Disk service with a
public cache and an ETag). It reads and writes the SQLite schema Rails built, so a Rails database can be
mounted as is.

## Run

```sh
make dsl-check                 # parse and type-check campfire.axum.rb
make build                     # crate in /tmp/campfire_axum_dsl-out
make e2e-campfire              # build, then test/e2e_campfire.sh (needs curl and sqlite3)

# by hand: a fresh database from the schema and the seed, then the server on :8099
sqlite3 /tmp/campfire.sqlite3 < db/migrate/001_schema.sql && sqlite3 /tmp/campfire.sqlite3 < test/seed.sql
cd /tmp/campfire_axum_dsl-out && SECRET_KEY_BASE=$(head -c 32 /dev/zero | tr '\0' x) DATABASE_PATH=/tmp/campfire.sqlite3 \
  /tmp/axum_dsl_target/debug/campfire
```

The seed's users all have the password `campfire-test-pw` (david@37signals.com is the administrator). The server
must run with the crate directory as its working directory: `/assets` is served from the copied `public/`.

## Settings

| Variable | Meaning |
|----------|---------|
| `SECRET_KEY_BASE` | at least 32 bytes; the session cookie and the avatar `signed_id` token are signed with it |
| `DATABASE_PATH` | the SQLite file (the benchmark mounts Rails' `/rails/storage/db/production.sqlite3`) |
| `ACTIVE_STORAGE_PATH` | the local Disk service root; default `storage/files` (the benchmark mounts Rails' `/rails/storage/files`) |

## Layout

- `campfire.axum.rb`: the root service — server, port, settings, cookies, the static mount, the database and
  migrations — then the `use_dsl` lines that splice in the declarations below, in declaration order.
- `models/`: one fragment per model — `user.axum.rb`, `session.axum.rb`, `current.axum.rb`, `room.axum.rb`,
  `message.axum.rb`, `avatar.axum.rb` — each holding its records, queries/executes and currents as it needs
  them (the session fragment has no record; `current.axum.rb` holds `current :user, required: :authenticate`).
- `controllers/`: one fragment per controller — `sessions.axum.rb`, `rooms.axum.rb`, `sidebars.axum.rb`,
  `searches.axum.rb`, `health.axum.rb`, `avatars.axum.rb` — holding the routes; `params.axum.rb` holds the
  params blocks; `authenticate.axum.rb` holds the shared `before :authenticate` filter (the public routes and
  `/assets` skip it).
- `views/`: the layout, pages and the message-list partial. `public/campfire.css`.
- `db/migrate/001_schema.sql`: `db/schema.rb` as `IF NOT EXISTS` statements, FTS5 index included.
- `test/seed.sql`, `test/e2e_campfire.sh`: the seed and the HTTP check.

The stylesheet is fingerprinted (`digest: true`), so `public/campfire.css` is served only as `/assets/campfire-<sha256 prefix>.css`, and `views/layout.html` writes the URL with `{{ asset_path "campfire.css" }}`, so it follows the file's bytes.
A room visit sets `last_room` (a plain, HttpOnly, SameSite=Lax cookie holding only the room id), and `GET /` sends the user to it when they are still a member, else to their first membership. Room pages carry a strong `ETag` from the newest message id, so a matching `If-None-Match` is a bodiless 304.
`POST /session` is rate-limited per client address (`use_layer :rate_limit, per: 60, burst: 20, path: "/session"`: 20 a minute, then 429); `GET /session/new` is outside the exact path. Behind a proxy the key is the peer address unless the deployment forwards the client address (`use_layer :trace, forwarded: true`).
