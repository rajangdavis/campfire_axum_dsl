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
# ActionDispatch::RemoteIp: request.remote_ip is the first X-Forwarded-For entry. Rails trusts that header only from a
# private or loopback proxy; this port trusts it unconditionally, as the trace layer's `forwarded: true` does, so the
# service has to stay behind a proxy that sets it. BlockBannedRequests#reject_banned_ip asks Ban.banned?(request.remote_ip),
# so this is what names the banned client.
set :trust_forwarded_for, true

# The key the session cookie is signed with (at least 32 bytes). Rails' SECRET_KEY_BASE, though the cookie format
# is this DSL's own: the token is signed, not Rails' MessageVerifier format (GAPS.md).
setting :secret_key, env: "SECRET_KEY_BASE", secret: true
cookies secret: :secret_key

# A write from another site answers 403 (Campfire has Rails' CSRF token; this is Fetch Metadata only).
use_layer :fetch_metadata

# Rails forms send update and delete as a POST with a hidden `_method` field; Rack::MethodOverride routes them as PATCH/DELETE.
use_layer :method_override

# POST /session is the login action: 10 requests in 3 minutes per client address, then 429, as Rails'
# `rate_limit to: 10, within: 3.minutes`. `path:` is one exact path, so GET /session/new (the form) stays outside it.
use_layer :rate_limit, per: 180, burst: 10, path: "/session"

# Rails' default response headers for the HTML pages and fragments (replacing :private_cache, whose
# `private, no-cache` + `Vary: Cookie` Rails does not send): the security headers, X-Version/X-Rev from the
# settings below, Rack::ETag with its `max-age=0, private, must-revalidate`, `Vary: Accept` for Accept-negotiated
# requests, the stylesheet preload Link, and the session cookies Rails rewrites on each authenticated response.
# The fingerprinted /assets mount is public bytes and stays outside.
use_layer :rack_defaults, security_headers: true, version: :app_version, revision: :git_revision, etag: true,
          vary_accept: true, refresh_cookies: ["session_token"],
          session_cookie: "_campfire_session", except: ["/assets", "/404.html", "/422.html", "/500.html", "/502.html"],
          # stylesheet_link_tag :all preloads every stylesheet the layout links, in its order (views/layout.html).
          preload: %w[_reset.css actiontext.css animation.css autocomplete.css avatars.css base.css boosts.css buttons.css
                      code.css colorize.css colors.css composer.css embeds.css filters.css flash.css inputs.css layout.css
                      lexxy-content.css lexxy-editor.css lexxy-variables.css lexxy.css lightbox.css messages.css nav.css
                      panels.css separators.css sidebar.css signup.css spinner.css trix.css utilities.css]

# Rack::Deflater and Thruster in front of Rails: gzip for a client that takes it, `Vary: accept-encoding` after the
# page's own tokens (`accept, accept-encoding`), and Thruster's cache with its `X-Cache: miss/hit/bypass` (the
# public max-age assets are what it keeps). Outside :rack_defaults, so the ETag is over the identity body.
use_layer :front

# views/*.html: the layout, the pages and the partial; the stylesheet is served from public/ under /assets.
set :views, "views"
set :layout, :layout
# MessagesHelper#message_presentation: the last sanitisation layer a text message passes through is auto_link
# with Rails' default safe-list plus the editor's formatting (ContentFilters::EDITOR_FORMATTING_TAGS and
# _ATTRIBUTES), so `figure` (the table wrapper) is not listed and unwraps, links get no `rel`, and bare URLs are
# linked with target="_blank".
sanitizer :message_body,
          tags: %w[strong em b i p code pre tt samp kbd var sub sup dfn cite big small address hr br div span h1 h2 h3 h4 h5 h6
                   ul ol li dl dt dd abbr acronym a img blockquote del ins s u mark table thead tbody tfoot tr th td],
          attributes: %w[href src width height alt cite datetime title class name xml:lang abbr data-language],
          link_rel: false,
          autolink_target: "_blank",
          # lib/rails_ext/actiontext_opengraph_embeds.rb: a link preview is drawn by views/opengraph_embed.html. The
          # view passes the request host, which keeps a preview from pointing at this server.
          # users/_mention: a mention names a User by its attachable sgid (the sanitize call passes the users).
          attachments: { "application/vnd.actiontext.opengraph-embed" => :opengraph_embed, "application/vnd.campfire.mention" => :mention },
          # app/models/sound.rb BUILTIN: a body of exactly `/play NAME` is drawn by views/sound_with_text.html or
          # views/sound_with_image.html (messages_helper.rb message_sound_presentation). The sound is NAME.mp3 and an
          # image is under public/sounds, both fingerprinted by the asset mount below.
          sound_partials: { text: :sound_with_text, image: :sound_with_image },
          sounds: {
            "56k" => ["sounds/56k.webp", 79, 33], "bell" => "🔔", "bezos" => "😆💭", "bueller" => "anyone?", "butts" => "👐 🚬",
            "clowntown" => ["sounds/clowntown.webp", 210, 150], "cottoneyejoe" => "🎶🙉🎶 ", "crickets" => "hears crickets chirping",
            "curb" => ["sounds/curb.webp", 150, 101], "dadgummit" => "dad gummit!! 🎣", "dangerzone" => ["sounds/dangerzone.webp", 157, 32],
            "danielsan" => "🎆 🏆 🎆", "deeper" => ["sounds/top.webp", 188, 80], "ballmer" => "developers!",
            "donotwant" => ["sounds/donotwant.webp", 150, 150], "drama" => ["sounds/drama.webp", 300, 16], "flawless" => "#flawless",
            "glados" => "🤖💢", "gogogo" => "Go, go, go!", "greatjob" => ["sounds/greatjob.webp", 79, 16], "greyjoy" => "😖🎺",
            "guarantee" => "guarantees it 👌", "heygirl" => "✨💁✨", "honk" => "HONK", "horn" => "🐶 ✂️ 🐱",
            "horror" => "💀 💀 💀 💀 💀 💀 💀", "inconceivable" => "doesn't think it means what you think it means…",
            "letitgo" => "❄️👩❄️⛄️❄️", "live" => "is DOING IT LIVE", "loggins" => ["sounds/loggins.webp", 200, 151],
            "makeitso" => "make it so 👉", "noooo" => "👸💀😒", "nyan" => ["sounds/nyan.webp", 36, 15], "ohmy" => "raises an eyebrow 😏",
            "ohyeah" => "isn't playing by the rules", "pushit" => ["sounds/pushit.webp", 104, 15], "rimshot" => "plays a rimshot",
            "rollout" => "is rolling out 🚗", "rumble" => ["sounds/rumble.webp", 220, 150], "sax" => "🌇🎷🎶",
            "secret" => "found a secret area 🔑", "sexyback" => "🔞", "story" => "and now you know…", "tada" => "plays a fanfare 🎏",
            "tmyk" => "✨ ⭐️ The More You Know ✨ ⭐️", "totes" => "😁👍", "trololo" => "трололо", "trombone" => "plays a sad trombone",
            "unix" => "knows this 💻", "vuvuzela" => "======<() ~ ♪ ~♫", "what" => ["sounds/what.webp", 100, 131],
            "whoomp" => "👏‼️😎", "wups" => "wups!", "yay" => ["sounds/yay.webp", 103, 50], "yeah" => ["sounds/yeah.webp", 104, 15],
            "yodel" => "📣🗻🙉"
          }
# Active Storage's local Disk service root (config/storage.yml `local`: Rails.root/storage/files). A blob's
# path is <root>/<key[0,2]>/<key[2,2]>/<key>; ACTIVE_STORAGE_PATH overrides it for a mounted benchmark seed.
setting :storage, env: "ACTIVE_STORAGE_PATH", default: "storage/files"
# The size in MB of the whole-response cache of the `cache: :private` routes (AP1); 0 turns it off. `type: :i64`
# because a setting without a type is text and a numeric default needs the integer type.
setting :response_cache_mb, env: "CAMPFIRE_RESPONSE_CACHE_MB", default: 64, type: :i64
# config/initializers/version.rb: the version badge (APP_VERSION, else GIT_REVISION, else "0").
setting :app_version, env: "APP_VERSION", default: "0"
# The same initializer's X-Rev header (GIT_REVISION); empty writes no header, as Rails drops a nil one.
setting :git_revision, env: "GIT_REVISION", default: ""
# layouts/application.html.erb: the vapid-public-key meta (Rails.configuration.x.vapid.public_key).
setting :vapid_public_key, env: "VAPID_PUBLIC_KEY", default: ""
# The asset mount stays public: the e2e fetches the fingerprinted name with no session. `digest: true` serves
# only `<stem>-<8 hex digits><ext>`, Propshaft's digest (so the names are Rails' own, and a stylesheet's
# `url(...)`/`@import` name the digested files), the layout writes that URL with `{{ asset_path "campfire.css" }}`,
# and `max_age:` is the lifetime Rails sends on assets (`Cache-Control: max-age=2592000, public`).
static "/assets", dir: "public", digest: true, max_age: 2592000, skip: [:authenticate, :allow_browser]

# Rails serves public/404.html ... 502.html as plain files at their own paths: serve_file, outside :authenticate.
# The 404 page is also read by the not_found filter (controllers/errors.axum.rb).
serve_file "/404.html", from: "public/errors/404.html", max_age: 2592000, skip: [:authenticate, :allow_browser]
serve_file "/422.html", from: "public/errors/422.html", max_age: 2592000, skip: [:authenticate, :allow_browser]
serve_file "/500.html", from: "public/errors/500.html", max_age: 2592000, skip: [:authenticate, :allow_browser]
serve_file "/502.html", from: "public/errors/502.html", max_age: 2592000, skip: [:authenticate, :allow_browser]
file "public/errors/404.html", as: :page_404
# Users::AvatarsController sends the default-bot avatar with send_file; the response names this file.
file "public/default-bot-avatar.svg", as: :default_bot_avatar_file
# Accounts::LogosController#send_stock_icon sends the stock app icon when the account has no logo.
file "public/logos/app-icon.png", as: :stock_logo_file, binary: true
file "public/logos/app-icon-192.png", as: :stock_logo_small_file, binary: true

# Rails image_url / session_url write absolute URLs from the request host: bodies read it with request_base_url.
# app/views/pwa/service_worker.js, served as text/javascript (controllers/pwa.axum.rb).
file "pwa/service_worker.js", as: :service_worker

database :sqlite, path: "campfire.sqlite3", env: "DATABASE_PATH"
migrations "db/migrate"

# The declarations are split Rails-shaped; use_dsl splices them in here, in declaration order.
use_dsl "models/user.axum.rb"             # record :User, active_user_by_email, user_for_session
use_dsl "models/session.axum.rb"          # start_session, end_session
use_dsl "models/current.axum.rb"          # current :user, after the session queries it reads
use_dsl "models/ban.axum.rb"              # banned_ip: Ban.banned? for BlockBannedRequests
# Rails' before_action order is require_authentication then reject_banned_ip. An axum Router::layer wraps outward, so
# the filter declared first is the innermost and runs last: this file is included before authenticate.axum.rb to put
# the ban check inside :authenticate, as Rails does (an unauthenticated non-GET still redirects to /session/new,
# while POST /session, which skips authentication, is still checked).
use_dsl "controllers/banned_ips.axum.rb"   # before :reject_banned_ip, ApplicationController's BlockBannedRequests
use_dsl "controllers/authenticate.axum.rb" # before :authenticate: the signed-in filter every controller shares
use_dsl "models/room.axum.rb"             # record :Room, room_for_user, first_room_id, shared/direct rooms
use_dsl "models/message.axum.rb"          # record :MessageRow, pagination, search, the message writes
use_dsl "models/bot_api.axum.rb"          # record :BotMessage, :BotBoost, bot_actor and the bot API queries
use_dsl "models/avatar.axum.rb"           # record :Avatar, the processed variant's blob key
use_dsl "models/autocomplete.axum.rb"     # record :AutocompleteUser, name-filtered active users
use_dsl "models/account.axum.rb"          # record :AccountPage, account_page: name, join code, logo version, administrator
use_dsl "models/sidebar.axum.rb"         # record :SidebarDirect/:SidebarRoom/:SidebarUser/:SidebarFlags, sidebar queries
use_dsl "models/room_form.axum.rb"        # record :RoomFormUser, :RoomFormRoom, the new/edit form queries
use_dsl "controllers/platform.axum.rb"   # pwa_browser, pwa_flag, pwa_blocked: ApplicationPlatform and allow_browser, from the User-Agent
use_dsl "controllers/params.axum.rb"     # Login, RoomPath, PageParams, SearchParams, NewMessage, AvatarPath
use_dsl "controllers/sessions.axum.rb"    # GET /session/new, POST/DELETE /session, GET /
use_dsl "controllers/rooms.axum.rb"       # GET /rooms/:id, its messages page and post
use_dsl "controllers/users.axum.rb"       # GET /join/:join_code, GET /session/transfers/:id
use_dsl "controllers/profiles.axum.rb"    # GET /users/me/profile
use_dsl "controllers/qr_code.axum.rb"     # GET /qr_code/:id
use_dsl "controllers/active_storage.axum.rb" # GET /rails/active_storage/representations/redirect/..., /disk/...
use_dsl "controllers/avatars.axum.rb"     # GET /users/:token/avatar
use_dsl "controllers/autocomplete.axum.rb" # GET /autocompletable/users(.json)
use_dsl "controllers/bot_messages.axum.rb" # the bot API: GET/PUT /rooms/:id/:bot_key/messages, POST .../boosts
use_dsl "controllers/account.axum.rb"      # GET /account/edit, /account/bots, /account/custom_styles/edit
use_dsl "controllers/push_subscriptions.axum.rb" # GET /users/me/push_subscriptions
use_dsl "controllers/sidebars.axum.rb"    # GET /users/me/sidebar
use_dsl "controllers/searches.axum.rb"    # GET /searches
use_dsl "controllers/room_fragments.axum.rb" # GET /rooms/:id/involvement, /refresh, /messages/:message_id
use_dsl "controllers/messages.axum.rb"   # GET .../messages/:id/edit, PATCH/DELETE .../messages/:id, /messages/:id/boosts
use_dsl "controllers/room_forms.axum.rb"    # GET /rooms/{opens,closeds,directs}/new and /:id/edit
use_dsl "controllers/errors.axum.rb"       # /404.html ... /502.html, the not_found page
use_dsl "controllers/logos.axum.rb"        # GET /account/logo
use_dsl "controllers/pwa.axum.rb"          # GET /webmanifest.json, /service-worker.js
use_dsl "controllers/health.axum.rb"      # GET /up

# Action Cable (docs/cable.md in ../axum_dsl): the six channels once-campfire's client subscribes to, over
# actioncable-v1-json. The endpoint authenticates itself from the upgrade request's session cookie
# (`current :user` above), so the named `before :authenticate` does not run for it. Each subscription is
# confirmed or rejected. PresenceChannel runs Membership.connect when confirmed, which is what clears the membership's
# unread_at (no GET does), then tells the user's ReadRoomsChannel. The broadcasts Rails makes are written where Rails
# makes them: Message::Broadcasts and Messages::BoostsController in controllers/rooms.axum.rb and messages.axum.rb,
# TypingNotificationsChannel's start/stop below. Room create/delete/membership broadcasts are not made yet (no such routes).
cable "/cable", authenticate_with: :user do
  # These two carry the room id; the membership query says whether the signed-in user may enter that room.
  # PresenceChannel#present: after Membership.connect, ActionCable.server.broadcast "user_#{current_user.id}_reads", { room_id: }.
  channel "PresenceChannel", room_param: :room_id, member_of: :room_for_user, on_subscribe: :connect_membership do
    after_subscribe { |user, room_id| broadcast "user_#{user.id}_reads", "room_id" => room_id }
  end
  # RoomChannel stream_for @room: typing_notifications:<the room's Global ID param>, which names the STI class, so the
  # membership query is the one that reads rooms.type. start/stop are broadcast_to @room with current_user.slice(:id, :name).
  channel "TypingNotificationsChannel", room_param: :room_id, member_of: :room_class_for_user do
    stream_for { |room| global_id_param(room.class_name, room.id, app: "campfire") }
    perform :start do |user|
      broadcast_to "action" => "start", "user" => json_object("id" => user.id, "name" => user.name)
    end
    perform :stop do |user|
      broadcast_to "action" => "stop", "user" => json_object("id" => user.id, "name" => user.name)
    end
  end
  # RoomMessagesChannel carries Turbo's signed stream name: the endpoint verifies the signature, derives the
  # room from the Global ID, and asks the same membership query before confirming.
  channel "RoomMessagesChannel", signed_stream: :secret_key, member_of: :room_for_user
  # Turbo's own room-list streams, rendered by the sidebar as two turbo-cable-stream-source elements: any
  # stream name signed with the same secret is confirmed, with no room check (Rails does the same).
  channel "Turbo::StreamsChannel", signed_stream: :secret_key
  # These three carry only the channel name.
  channel "ReadRoomsChannel" do
    stream_from { |user| "user_#{user.id}_reads" }
  end
  channel "HeartbeatChannel"
  # UnreadRoomsChannel.stream_name_for(user_id)
  channel "UnreadRoomsChannel" do
    stream_from { |user| "user_#{user.id}_unreads" }
  end
end
