# typed: false
# Campfire C1: the first slice of Basecamp's Campfire (once-campfire) written in axum_dsl, with no Rust of the app's
# own. It reads and writes the same SQLite schema Rails built (db/migrate/001_schema.sql is IF NOT EXISTS, so a Rails
# database is left alone), so the benchmark's seeded database can be mounted as DATABASE_PATH. C1 covers: sign in and
# out, a room page (the newest 40 messages), the earlier-messages page, the sidebar, search, /up and one stylesheet.
# What the DSL could not say is in GAPS.md, each with the once-campfire line it comes from.
# test/e2e_campfire.sh drives it; the axum_dsl examples hold 8080-8098, so this service takes 8099.
server "campfire", version: "0.1.0"
set :port, 8099
set :rust, :none

# The key the session cookie is signed with (at least 32 bytes). Rails' SECRET_KEY_BASE, though the cookie format
# is this DSL's own: the token is signed, not Rails' MessageVerifier format (GAPS.md).
setting :secret_key, env: "SECRET_KEY_BASE", secret: true
cookies secret: :secret_key

# A write from another site answers 403 (Campfire has Rails' CSRF token; this is Fetch Metadata only).
use_layer :fetch_metadata

# POST /session is the login action: 20 requests a minute per client address, then 429. `path:` is one exact
# path, so GET /session/new (the form) stays outside it.
use_layer :rate_limit, per: 60, burst: 20, path: "/session"

# Signed cookies carry the session, so every response is private to the browser: `private, no-cache` stops a
# shared cache storing a room page, and `Vary: Cookie` keys anything a cache does keep on the session. The
# fingerprinted stylesheet is public bytes named by their hash, so it is the one exemption: its mount keeps
# no cache header of the layer's, and a shared cache may store it like any other static file.
use_layer :private_cache, except: ["/assets"]

# views/*.html: the layout, the pages and the partial; the stylesheet is served from public/ under /assets.
set :views, "views"
set :layout, :layout
# Active Storage's local Disk service root (config/storage.yml `local`: Rails.root/storage/files). A blob's
# path is <root>/<key[0,2]>/<key[2,2]>/<key>; ACTIVE_STORAGE_PATH overrides it for a mounted benchmark seed.
setting :storage, env: "ACTIVE_STORAGE_PATH", default: "storage/files"
# The asset mount stays public: the e2e fetches the fingerprinted name with no session. `digest: true` serves
# only `<stem>-<twelve hex digits of SHA-256><ext>`, so the name follows the file's bytes, and the
# layout writes that URL with `{{ asset_path "campfire.css" }}`.
static "/assets", dir: "public", digest: true, skip: [:authenticate]

database :sqlite, path: "campfire.sqlite3", env: "DATABASE_PATH"
migrations "db/migrate"

# The declarations are split Rails-shaped; use_dsl splices them in here, in declaration order.
use_dsl "models/user.axum.rb"             # record :User, active_user_by_email, user_for_session
use_dsl "models/session.axum.rb"          # start_session, end_session
use_dsl "models/current.axum.rb"          # current :user, after the session queries it reads
use_dsl "controllers/authenticate.axum.rb" # before :authenticate: the signed-in filter every controller shares
use_dsl "models/room.axum.rb"             # record :Room, room_for_user, first_room_id, shared/direct rooms
use_dsl "models/message.axum.rb"          # record :MessageRow, pagination, search, the message writes
use_dsl "models/avatar.axum.rb"           # record :Avatar, the processed variant's blob key
use_dsl "controllers/params.axum.rb"     # Login, RoomPath, PageParams, SearchParams, NewMessage, AvatarPath
use_dsl "controllers/sessions.axum.rb"    # GET /session/new, POST/DELETE /session, GET /
use_dsl "controllers/rooms.axum.rb"       # GET /rooms/:id, its messages page and post
use_dsl "controllers/avatars.axum.rb"     # GET /users/:token/avatar
use_dsl "controllers/sidebars.axum.rb"    # GET /users/me/sidebar
use_dsl "controllers/searches.axum.rb"    # GET /searches
use_dsl "controllers/health.axum.rb"      # GET /up
