# Gaps: what Campfire needs and axum_dsl cannot yet say

Found while writing C1 (`campfire.axum.rb`). No `rust_fn`/`rust_file` hatch was used. Each entry: what Campfire
needs, where in once-campfire, what the DSL lacks, and the smallest compiler feature that removes it.
Paths are under once-campfire; "workaround" says what this wave did instead.

## 1. `redirect` is a 303; Campfire answers 302
- Needs: `redirect_to` is a 302. The verification login (`loadgen/src/main.rs` `fn login`) fails unless `POST /session` answers 302.
- Where: `app/controllers/sessions_controller.rb:13` (`redirect_to post_authenticating_url`), `app/controllers/concerns/authentication.rb:52,56`.
- Lacks: `redirect(path)` is axum's `Redirect::to`, which is 303 (body.rb `redirect_response`; its own comment says 302).
- Smallest feature: `redirect(path, status: 302)` (or make the default 302, as in Rails/Sinatra).
- Closed 2026-10-17 by AX11/AX13: `redirect` answers 302 by default and takes `status:`. The login route now ends in `redirect("/")` after `set_cookie`, and every other redirect is the 302 Rails answers, too.

## 2. A status or content type on one branch of a route
- Needs: a wrong login re-renders the form with a 401 (`render :new, status: :unauthorized`), a success redirects.
- Where: `app/controllers/sessions_controller.rb:12-23` (`render_rejection`), also `messages_controller.rb:16-19` (`head :no_content`).
- Lacks: `render` and `html` take no status; `status(...)` applies to the whole body's final response, so it cannot differ per branch; `halt(status, body)` takes a plain string and so answers `text/plain`.
- Smallest feature: `render :view, status: 401, locals: {...}` (and `html(s, status:)`), usable in a `return`.
- Closed 2026-10-17 by AX11/AX13: `render` takes `status:`, which travels on the value a `return` carries. The wrong login is now `return render(:session_new, status: 401, locals: { title: "Sign in" })`: the real form, with the layout, as a 401. The 204 is unchanged (`halt(204, "")`).

## 3. Calling a statement for its effect
- Needs: run `DELETE FROM sessions` and carry on.
- Where: `app/controllers/concerns/authentication.rb:70-75` (`terminate_current_session`).
- Lacks: a bare `execute` call is refused as a statement (only `name = expr`, a guard, `status`, `headers`, `.each` may precede the last expression), and an unused local is refused too.
- Smallest feature: allow a bare `execute`/`query` call as a statement (its count dropped), or `_ = ...`.
- Closed 2026-10-17 by AX11/AX13: a bare `execute`/`query` call is a statement and its value is dropped. Logout is now `end_session(token: token)` followed by `redirect("/session/new")`, Rails' target, with no `?ended=` copy of login.axum.rb.

## 4. `[[:word:]]` in a regex
- Needs: `params[:q]&.gsub(/[^[:word:]]/, " ")` (Unicode word characters survive).
- Where: `app/controllers/searches_controller.rb:41`.
- Lacks: the regex translator rejects POSIX classes (a parallel wave adds `[[:word:]]`).
- Smallest feature: translate `[[:word:]]` to Rust's `\w`.
- Closed 2026-10-17 by AX9: `regex_translate.rb` emits `[^\p{Alphabetic}\p{M}\p{Nd}\p{Pc}]`, and campfire.axum.rb uses `[^[:word:]]` as Campfire does.

## 5. Action Text bodies are HTML, and nothing sanitises
- Needs: a message body is rich text: `message_presentation(message)` renders `action_text_rich_texts.body` through Action Text's sanitiser, so allowed tags, links and attachments show as markup.
- Where: `app/models/message.rb:9` (`has_rich_text :body`), `app/views/messages/_presentation.html.erb:2`, `app/helpers/messages_helper.rb:58` (`message_presentation`).
- Lacks: no HTML sanitiser (allowlist of tags/attributes, `javascript:` URLs) in the body language or in views; `|raw` is the only door and unsafe for user HTML.
- Smallest feature: a built-in `sanitize(html, tags: [...], attributes: [...])` (ammonia) usable as `{{ body|sanitize }}`.
- Closed 2026-10-17 by AX11/AX13: a `{{ name|sanitize }}` view filter runs ammonia (its default allowlist plus `class`). `views/message_list.html` now renders `{{ message.body|sanitize }}`, so the Trix `div` and its class survive while the body's text stays escaped, as Action Text renders it.

## 6. A conditional in a view
- Needs: `<% if %>` throughout, e.g. only show the flash, the `shake` class, unread dots, `Current.user.administrator?` buttons.
- Where: `app/views/sessions/new.html.erb:5` (`"shake" if flash[:alert]`), `app/views/users/sidebars/show.html.erb:39` (`if Current.user.administrator? || ...`), `app/views/messages/_message.html.erb`.
- Lacks: views had six markers and no conditional at the time (AX12 later added `{% if %}`; AX13 added `|sanitize`).
- Smallest feature: `{% if name %}...{% endif %}` on a bool/non-empty local, so route logic stays in the body but a view can omit markup.
- Closed 2026-10-17 by AX12: `{% if name %}...{% else %}...{% endif %}` over a bool or nil-able local or loop field, Ruby truthiness, with an `if let` narrowing inside the branch. C1 does not need it yet; the blank-search case stays in the route with a ternary and a `no_messages` query.

## 7. Per-path `before` filters
- Needs: `before_action :require_authentication` on every controller except `allow_unauthenticated_access` actions.
- Where: `app/controllers/concerns/authentication.rb:6`, `sessions_controller.rb:2`, `app/controllers/welcome_controller.rb`.
- Lacks: a `before` filter runs for every route (sessions.md), so the redirect cannot be a filter.
- Smallest feature: `before except: [...]` / `before only: [...]` (or path-scoped filters).
- Workaround: every route starts `user = current(:user); return redirect("/session/new") if user.nil?` (8 routes).
- Closed 2026-10-17 by AX14: `before :authenticate do ... end` names the filter, a route or a `static` mount says `skip: [:authenticate]`, and `current :user, returns: :User?, required: :authenticate` reads non-nil in every route that does not skip it. The per-route `current(:user)` nil guards are gone; the login actions, `/up` and the `/assets` mount skip the filter.

## 8. The session cookie format
- Needs: `cookies.signed.permanent[:session_token]`, a Rails MessageVerifier value, so a Rails browser session survives a switch of server.
- Where: `app/controllers/concerns/authentication.rb:94` (set), `:98` (delete), `SessionLookup` (read).
- Closed 2026-10-17: `format: :rails7` reads a default Rails 7/8 signed cookie (JSON/`_rails`, PBKDF2-HMAC-SHA256 key) with a null metadata `exp` or the UTC ISO8601 string `Messages::Metadata.pick_expiry` writes (`expires_at.utc.iso8601(3)`), enforces a non-null one as strictly after now (and refuses an integer, as Rails' `parse_expiry`/`Time.iso8601` would raise), and writes it for `permanent: true`/`max_age:`. Rails' `cookie_metadata` passes only `:expires`, so a Rails `max_age` alone writes `exp: null`; our `max_age:` writes the same instant as its HTTP `Max-Age`, which is valid to Rails and tighter. `cookies.signed.permanent` is therefore read and written.
- Closed 2026-10-17: `format: :rails`, `format: :rails7` and the signed permanent/max_age ISO8601 `exp` landed.

## 9. Rate limiting
- Needs: `rate_limit to: 10, within: 3.minutes, only: :create` on login.
- Where: `app/controllers/sessions_controller.rb:3`.
- Lacks: any rate-limit layer.
- Smallest feature: `use_layer :rate_limit, per: 3.minutes, burst: 10, path: "/session"` (tower-governor), keyed by `request_ip`.
- Workaround: left out.
- Closed 2026-10-17: `use_layer :rate_limit, per: 60, burst: 20, path: "/session"` in `campfire.axum.rb`; `per:` is seconds, `burst:` the count in the window, `path:` one exact path, keyed by `request_ip`, 429 past the burst (the compiler's std-only fixed-window limiter, no tower-governor). `GET /session/new` is outside the path.

## 10. CSRF tokens
- Needs: `protect_from_forgery` with `authenticity_token` in forms (`loadgen` sends it only when the login page carries one).
- Where: `app/controllers/concerns/authentication.rb:10`.
- Lacks: only `use_layer :fetch_metadata`.
- Smallest feature: a `csrf_token` value for views plus a verifying layer.
- Workaround: Fetch Metadata only (the layer is on); forms carry no token.

## 11. `last_room` cookie, `fresh_when` (ETag / 304) and the unread/involvement writes
- Needs: `GET /` goes to the last room visited (a plain cookie); `messages#index` answers `fresh_when @messages` (ETag, 304); visiting a room clears `unread_at`.
- Where: `app/controllers/concerns/tracked_room_visit.rb:9-13`, `app/controllers/messages_controller.rb:14`, `app/controllers/rooms_controller.rb` (`remember_last_room_visited`).
- Lacks: unsigned cookies, computed response headers (`headers` takes literals only), conditional GET.
- Smallest feature: `cookie(:name, signed: false)`, computed `headers`, `etag(value)`.
- Closed in part 2026-10-17: `GET /rooms/:id` sets `last_room` (unsigned, HttpOnly, SameSite=Lax, host-only, the room id only) and answers a strong `ETag: "room-<newest message id>"`, a matching `If-None-Match` as a bodiless 304; `GET /` resolves the cookie through `room_for_user`, so an id the user is not a member of, or no id, falls back to the first membership. The cookie is a navigation hint, not authorization, so it stays unsigned like Rails' plain cookie.
- Closed in part 2026-10-17: visiting a room clears `unread_at` — both `GET /rooms/:id` and `GET /rooms/:id/messages` run a `clear_unread` execute statement for the current membership immediately after the membership guard, before the ETag, so even a 304 clears. The reference does not clear it in `tracked_room_visit.rb` (that concern only remembers `last_room`); once-campfire clears it when the room's presence channel subscribes (`Membership::Connectable#present`, reached from `PresenceChannel`). Superseded 2026-10-28: the room reads no longer clear it; the cable's `on_subscribe: :connect_membership` on PresenceChannel runs Membership.connect (unread_at cleared, connections and connected_at set) when the subscription is confirmed. `broadcast_read_room` and the disconnect side (`on_unsubscribe`) are not implemented. The involvement write (a mention creating or updating a membership) remains unimplemented.

## 12. Fingerprinted assets
- Needs: `href="/assets/application-<digest>.css"` with far-future caching (the harness only needs `/assets/*.css`).
- Where: Sprockets/Propshaft (`app/assets`), referenced from `app/views/layouts/application.html.erb:24`.
- Lacks: a digest in a `static` path or `Cache-Control` computed from the file.
- Smallest feature: `static "/assets", dir: "public", digest: true` and an `asset_path(:name)` for views.
- Workaround: a fixed `/assets/campfire.css`.
- Closed 2026-10-17: `static "/assets", dir: "public", digest: true, skip: [:authenticate]` in `campfire.axum.rb` serves only the fingerprinted name, and `views/layout.html` writes `href="{{ asset_path "campfire.css" }}"`; the name follows the file's bytes, so no digest is written down here. The generated `ServeDir` sends no `Cache-Control` of its own: the fingerprint only makes a far-future header safe, and setting it was left to the deployment. Since closed: `static ... max_age: 2592000` sends Rails' `Cache-Control: max-age=2592000, public`.
- Closed 2026-10-17: `campfire.axum.rb` declares `use_layer :private_cache, except: ["/assets"]`, so the fingerprint mount no longer carries `private, no-cache`/`Vary: Cookie`; the layer still covers every page. The far-future header is now the `static` mount's `max_age: 2592000` (see above).

## 13. A form field name that Rails spells with brackets
- Needs: Campfire's message form posts `message[body]` (and `message[client_message_id]`), so `MessagesController#create`
  reads `params[:message][:body]`.
- Where: once-campfire's message form (`form_with model: message`, the `body` text area) and `MessagesController#create`'s
  `params[:message]`; the wire names are `message[body]` and `message[client_message_id]`.
- Lacks: a params field name is a `:snake` symbol (`field` in `SIG`), so it cannot be written `:"message[body]"`, and a
  `:form` group is flat key/value pairs: serde_urlencoded builds no nested form object.
- Smallest feature: `field :body, :string, in: :form, name: "message[body]"` (the struct field and the wire key apart), or a
  one-level nested form object.
- Closed 2026-10-17: `field :body, :string, in: :form, name: "message[body]"` (and the `client_message_id` field) is a
  serde rename on the generated struct, so the wire key is Rails' while `params[:body]`, `check()` and `errors` keep the
  DSL name; `controllers/params.axum.rb` declares both, the e2e posts the bracketed names and asserts the three rows, and
  a flat `body=` is a 422 by design.
- The write is one transaction (the compiler's `transaction do ... end`): the message (`RETURNING id`), its Action Text
  body and its FTS row commit together or roll back together, so a failure between them leaves no message without its
  body and/or its FTS row.

## 14. Out of C1/C2 scope, noted for later waves
The Turbo Stream response landed in C2: `POST /rooms/:id/messages` answers `text/vnd.turbo-stream.html` with an
`append` into `messages_room_<id>`. The avatar route landed in C3 (`GET /users/:token/avatar`, section 15). Since then
the Action Cable endpoint, the account and bot pages, and the bot message API have landed (the parity run of
2026-11-04 passes every default-seed state on Chromium desktop light and phone dark). Still out, as of 2026-11-04:
first run (section 21), the write routes behind several of those pages (section 21), Web Push delivery
(`test_notifications`: VAPID signing and aes128gcm) and link unfurling (`POST /unfurl_link`: an outbound HTTP fetch
and OpenGraph parsing). The last two need compiler features.

## 15. Rails signed IDs and a file response computed at request time
- Needs: `User.from_avatar_token(params[:user_id])` verifies `signed_id(purpose: :avatar)` and serves the stored
  `avatar.variant(:square).processed` from Active Storage; the harness's `avatar` route checks the bytes and asks
  ffprobe to decode them (`bench/contracts.rb:12-21,54-55,78`).
- Lacks: a body could not return file bytes (only `text`/`html`/`json`/`render` and the static `serve_file`), and
  there was no Rails signed-ID verifier.
- Smallest feature: `send_file(path, content_type:)`, a response helper that awaits `tokio::fs::read` at request
  time and answers the bytes (500 on a read failure; the caller checks its row and answers 404); and
  `rails_signed_id(token, purpose: "user/avatar", secret: :secret_key)`, the Rails 8
  `ActiveRecord.message_verifiers["active_record/signed_id"]` verifier (PBKDF2-HMAC-SHA256 key from
  SECRET_KEY_BASE, SHA256/JSON/url-safe metadata envelope, purpose, integer id). The app declares
  `setting :storage, env: "ACTIVE_STORAGE_PATH", default: "storage/files"` for the Disk service root.
- Closed 2026-10-20: `app/models/user/avatar.rb:11-13,16-21` and
  `app/controllers/users/avatars_controller.rb:6-19,28-30` are lowered to `models/avatar.axum.rb`,
  `controllers/avatars.axum.rb` and the `send_file`/`rails_signed_id` compiler features. The e2e mints the token
  with real ActiveSupport where available (or a fixed Rails 8.2 token), checks image/webp, exact bytes twice,
  ffprobe, Cache-Control, ETag/304 and 404 for a bad token; it stores the variant at
  `<storage>/<key[0,2]>/<key[2,2]>/<key>`. Expiring signed IDs are refused (the avatar token has no expiry).
  A user with no avatar or no processed `:square` variant still answers 404 here; Rails' initials SVG and bot
  default remain out (section 14).

## 16. A side effect under a condition
- Needs: Rails' `Membership#read` (`update!(unread_at: nil)`) writes nothing when the marker is already clear,
  so a room visit is a write only the first time. The natural port is
  `clear_unread(...) unless unread_marker(...).nil?`, or the same as an `unless ... end` block.
- Closed 2026-10-30 in part: a non-guard `if`/`unless` with no else whose body is only bare
  `execute`/`query` calls, local assignments or nested conditionals compiles to a Rust `if` block; a body that
  leaves with `return`/`raise` remains a guard clause. The POST uses it to skip the two attachment inserts for a
  text message. Still refused: an `else` branch and non-SQL statements in the body.
- Worked around 2026-10-21 in SQL: `clear_unread`'s UPDATE gained `AND unread_at IS NOT NULL`, so it changes no
  row once the marker is clear (`models/room.axum.rb`). That alone took room_show from 296 to 4,113 rps and its
  p99 from 1,038 to 8 ms on `make bench-local` (raj-dev; WAVE-PLAN AP0), because every visit had been rewriting
  the row under SQLite's single write lock. The statement still opens a write transaction, so a read-first
  conditional would avoid even that once the compiler allows it.
- Smallest feature: a statement-level `if`/`unless` (no `else` needed) whose body is calls and assignments to
  existing locals, compiled to a Rust `if` block; guards keep their current form.

## 17. Uploads, notices and room revisions (the write forms)
- Built: `PATCH /account.:id` (name), `PATCH /users/me/profile` (name, e-mail, password, bio, avatar), `POST /join/:join_code`,
  the composer's `POST /rooms/:id/messages` with `message[attachment]`, `PATCH /rooms/closeds/:id`; `GET /rooms/:id/refresh` answers
  the public 404 page for a non-member.
- Notice (Rails' `redirect_to ..., notice:`): carried in the `_campfire_session` value as a suffix on the token
  (`.notice_saved` is "✓", `.notice_avatar` the 30 minutes text), shown once by the page the redirect lands on, which writes the
  bare token back (like `.room_not_found`). Each target page reads it inline into the explicit `flash_on/flash_alert/flash_text`
  locals. Lacks: a flash that any redirect target would show without repeating the cookie lines in every route.
- Lacks, image analysis: the blob's `width` and `height` metadata (Active Storage's analyzer), so a new image message has no
  `width`/`height` on its `<img>` and no `max-inline-size` box (`views/message_presentation*`, `models/message.axum.rb`
  message_presentation), unlike Rails (moon.jpg: 640x640, `style="width: 320px; aspect-ratio: 1.0;"`). Needs
  `upload.width`/`upload.height` (or an `analyze` that reads PNG/JPEG/GIF/WebP headers).
- Closed 2026-11-07, variants: the `:thumb` (resize_to_limit 1200x800) a message attachment gets and the `:square` (512x512 webp)
  an avatar gets, through axum_dsl's `image_variant` (models/variant.axum.rb); see the 2026-11-07 entry at the end.
- Closed 2026-10-29, disconnecting a user's cable connections: `close_remote_connections(user.id, reconnect: true)` (cable.md) is
  Rails' `User#close_remote_connections`: every open socket of that user is sent
  `{"type":"disconnect","reason":"remote","reconnect":true}` and closed, running `on_unsubscribe`. Wired where Rails calls it and
  the tree has the route: `PATCH /rooms/closeds/:id` for the people the update removes (Membership `after_destroy_commit`) and
  `DELETE /session` (`disconnect_remote_connections`). Not wired, on purpose: `DELETE /rooms/:id` (Room `dependent: :delete_all`
  skips the callback; the reference capture has no disconnect either). `User#deactivate` and a ban
  (`close_remote_connections reconnect: false`) have no route here yet. The client reconnects, the channels reject the room
  (`member_of:`), and the UnreadRoomsChannel reconnect reloads `#user_sidebar`. Unrun until `dsl-check`/`dsl-e2e` and the VM.
- Closed 2026-10-29: a join whose e-mail is already taken answers the sign-in form with the address prefilled
  (`UsersController#create`'s `rescue ActiveRecord::RecordNotUnique` → `new_session_url(email_address:)`), through
  `user_email_taken` and `url_encode`; and `PUT /session/transfers/:id` is `Sessions::TransfersController#update` (an
  expiring `user/transfer` signed id, then a session and `/`). The taken-e-mail check is a pre-check, not a rescue: the
  DSL cannot catch a unique-index failure, so two simultaneous joins with one address can still 500. Still lacks: a
  `redirect` path built from an arbitrary string — the path becomes the Location header, so only numbers, bools and
  `url_encode(...)` (ASCII by construction) may be interpolated, which covers a query value but not a path segment.

## 18. The editor's `value` when a message is edited
- Needs: `<lexxy-editor value="...">` of the edit form carries each attachment rebuilt from what it attaches, so Lexxy shows the mention chip: `content-type` set, `content` the attachable's partial as an ActiveSupport JSON string.
- Where: `app/helpers/rich_text_helper.rb` (`editable_body`), Lexxy's `render_custom_attachments_in`, `app/views/users/_mention.html.erb`, `app/views/messages/edit.html.erb`.
- Lacked: a way to write a body through the sanitizer's attachment partials without sanitising it (`value="{{ body }}"` passed the stored markup through, so there was no chip and the pixels, aria and network layers all differed).
- Closed 2026-10-29: `{{ body|editable :message_body, host: base_url, mentions: mentions }}` in `views/message_edit_form.html` (docs/views.md, "Attachments and sounds"), drawing with the same `views/mention.html` and `views/opengraph_embed.html` as the message; `views/mention.html` writes the user's `sgid` on its span, as `users/_mention` does (the message sanitizer drops it).

## Constructs least certain to compile (C1 could not build; C2 built the project, and `dsl-check`/`e2e_campfire.sh` now exercise the ones the service uses)
`no_messages()` with `args: {}`; a ternary choosing between two `list(:MessageRow)` values; `(params[:q] || "").gsub(...)`;
`return render(:session_new, status: 401, ...) if user.nil? || !Bcrypt.verify(...)` with a long guard; a partial with
`{% args messages: %}` whose loop variable is `message`; `redirect("/")` beside `set_cookie` in one body, and a bare
`end_session(...)` statement; `{{ message.body|sanitize }}` in a view; a repeated `:id` is avoided on purpose (each
query uses a placeholder once).

## 19. Banned-IP check runs after `rate_limit`
- Needs: Rails' `BlockBannedRequests` before_action runs before `SessionsController`'s `rate_limit`; a banned
  non-GET is 429 from the ban filter (empty `text/html`, with `rack_defaults` cookies/security headers) and is
  never rate-limited.
- Where: `app/controllers/concerns/block_banned_requests.rb` and `app/controllers/sessions_controller.rb:3`;
  candidate `controllers/concerns/banned_ips.axum.rb` and `campfire.axum.rb` (`use_layer :rate_limit`).
- Lacks: `:rate_limit` is a router layer, so it always runs outside the controller's `before` filters;
  `before :reject_banned_ip` cannot run first. In the shared full matrix the candidate's tenth-and-later POSTs
  from `{{ips.banned}}` answer from `rate_limit` (`text/plain`, no `Set-Cookie`, no security headers), while the
  reference answers from the ban filter (`text/html`, `no-cache`, `Set-Cookie`, security headers). The isolated
  `auth/sign_in/banned_ip` cell passes.
- Smallest feature: make `rate_limit` a named `before` filter (or give the layer a ban-aware skip), so the ban
  check can precede it. A test-only workaround is to mark `auth/sign_in/banned_ip` `mutates: true` in the
  inventory; not applied, because the reference tree is read-only.
- Evidence: 2026-10-31 full matrix, `candidate/auth/sign_in/banned_ip/*.network.txt` vs
  `reference/auth/sign_in/banned_ip/*.network.txt`; candidate 429 is `text/plain`, reference is `text/html` with
  `Set-Cookie` and `cache-control: no-cache`.

## 20. HTTP Date under the parity harness's fake clock (closed)
- Needs: the browser cache must see a real HTTP `Date`, as it does from the reference's Thruster, while
  application time remains at the seed instant for transfer/invitation tokens and expiries.
- Where: parity harness `FAKETIME`; candidate `axum_dsl/lib/axum_dsl/front.rb`.
- Fixed 2026-10-31: `front` now writes `Date` from `/proc/stat` btime + `/proc/uptime`, advanced by the real
  monotonic clock, and the candidate image keeps libfaketime for application time. `auth/sign_in/error`,
  `auth/transfer/valid`, and `auth/incompatible_browser` pass; the candidate/reference request count is 263/263.
  Removing `LD_PRELOAD` globally was wrong: it expired signed transfer/join tokens (`SystemTime::now` in
  `signed_id.rb`), which `auth/transfer/valid` and `auth/join/completed` caught.


## 21. First run and the write routes behind existing pages
- Needs: every form the pages render must reach a route. The parity server layer passes (the HTML matches Rails), but
  parity states are mostly page renders, so a form whose target route is missing still passes. Found 2026-11-04 by
  `test/write_routes.py`, which replays every form action, `_method` and `data-turbo-method` link in a parity run's
  Rails captures against Rails and the candidate on the default seed (18 missing on that seed), and by
  `once-campfire-verification`'s `bin/browser`, which stops at its first step.
- Missing (Rails answers; the candidate 404s or 405s): `GET`/`POST /first_run` (and `/session/new`'s redirect to it
  when there is no account); `POST /rooms/closeds`, `POST /rooms/directs`, `PATCH /rooms/opens/:id`,
  `DELETE /rooms/directs/:id`; `PUT /account.:id` (the restrict-room-creation toggle), `PATCH /account/custom_styles`,
  `PATCH`/`DELETE /account/users/:id`, `POST /account/join_code`; `POST /account/bots`, `PATCH`/`DELETE
  /account/bots/:id`, `PUT /account/bots/:id/key`; `POST`/`DELETE /users/:id/ban`, `DELETE /users/:id/avatar`;
  `POST /users/me/push_subscriptions`, `DELETE /users/me/push_subscriptions/:id`; `DELETE /searches/clear`;
  `POST /unfurl_link` (section 14).
- Also (fixed 2026-11-06, below): `PATCH /account.:id` from the logo form with no file chosen (Rails answers 400 for
  the missing `account` parameter), and `GET /account/bots/:id/edit` for an unknown bot (now 404). With the account's
  `restrict_room_creation_to_administrators` setting on, `GET /rooms/opens/new` as a member answers 200 where Rails
  answers 403 (parity `rooms/opens/new/restricted_member`, seed `restricted`).
- Rendering, from the parity states on the non-default seeds (2026-11-04, Chromium desktop light; `candidate compare
  --seed default` skips them): the layout never emits the account's custom CSS (`<style data-turbo-track="reload">`,
  8 `custom_styles` states); `<body>` lacks `account-has-logo` on the sign-in page and the member's account page, and
  the remove-logo button posts to `/account/logo` without Rails' `?v=<version>`; the account member list does not
  paginate (no lazy `next_page_container` frame, and `GET /account/users.turbo_stream?page=N` is a 404; 3 `crowd`
  states).
- Lacks: nothing in the compiler for most of them; existing routes are the templates (`POST /join/:join_code` for
  first run, `POST /rooms/opens` and `PATCH /rooms/closeds/:id` for the room forms, `PATCH /account.:id` and
  `PATCH /users/me/profile` for the rest).
- Done when: `test/write_routes.py` reports 0 missing, `bin/browser` passes unmodified against a fresh image, and the
  `first_run`, `crowd`, `custom_styles` and `restricted` seeds' parity states pass.
- Progress (2026-11-05): `GET`/`POST /first_run` and `GET /session/new`'s redirect to `/first_run` on an install with
  no users (`controllers/first_runs.axum.rb`, `views/first_run.html`). Against Rails on the `first_run` seed, the
  form's DOM is identical; the POST's rows (account, administrator, All Talk, its one membership, the session, an
  avatar blob) match apart from the bcrypt prefix (`$2b$` here, `$2a$` in Rails, as `POST /join` already does) and
  the avatar blob's `metadata`, which Rails' analyze job later fills with width and height. With no account the
  layout's icon links carry no `?v=`, so the page renders through `views/layout_no_account.html`.
- Compiler (fixed in axum_dsl, `Body#transaction_captures`): a local a `transaction` block read was moved into the
  `move` closure, so reading it after the block was E0382; each captured local is now cloned first, and `POST /join`
  no longer copies its session token.
- Progress (2026-11-05): `POST /rooms/closeds`, `POST /rooms/directs`, `DELETE /rooms/directs/:id` and
  `PATCH /rooms/opens/:id`. 18 differential scenarios against Rails (fresh default/restricted seeds; status, Location,
  every table row, and the sidebar frame and room pages after) all pass, including restricted creation (403), a
  found ping reused, a member's own closed room, a direct room through the opens form (redirect with the alert) and
  a closed room opened (every active user granted). `/` with no room now shows the alert a redirect carried (it was
  dropped). The cable broadcasts these send are not compared here.
- Progress (2026-11-05): Account -- `PATCH /account/custom_styles`, `POST /account/join_code`, `DELETE /account/logo`,
  `GET /account/users.turbo_stream?page=N` (and the edit page's lazy `next_page_container` past 500 people),
  `PATCH`/`DELETE /account/users/:id`. 20 differential scenarios pass (default, custom_styles and crowd seeds; member
  403s, inactive/banned 404s, a bogus role, a page past the end). Found by them and fixed: every account save writes
  has_json's default `settings` when NULL (the rename did not); the role form's duplicate `user[role]` was a 422 (the
  last value wins in Rails); the layout now writes the account's custom CSS (`<style data-turbo-track="reload">`, an
  empty string included), closing the `custom_styles` rendering gap. The logo's purge runs in the request, where Rails
  enqueues it (the rows match once the job has run; the files stay on disk).
- Compiler (fixed in axum_dsl): a ternary passed to a query or helper kept its parens (unused_parens under
  -Dwarnings); a local named like a params field hid it from later `params[:x]` reads, which rustc reported as a type
  error in generated code -- such a read is now refused with the DSL line (a plain `x = params[:x]` rebind is allowed).
- Progress (2026-11-05): Bots -- `POST /account/bots`, `PATCH`/`DELETE /account/bots/:id`, `PUT /account/bots/:id/key`;
  the bots pages now answer a member 403 (ensure_can_administer) and an unknown bot's edit page 404 (was 500). Bot API --
  `POST /rooms/:id/:bot_key/messages`, `DELETE .../messages/:id`, `DELETE .../messages/:id/boosts/:id`. 29 differential
  scenarios pass (bad and inactive keys, non-member rooms, blank bodies, someone else's message or boost).
- Fixed in the composer's `POST /rooms/:id/messages` (found by the bot API's control scenario): Room#receive now marks
  the other visible, disconnected members' memberships unread (the sidebar's unread badges); the room is touched
  (`belongs_to :room, touch: true`); the FTS row holds the body's plain text, not its HTML.
- Not reproduced: a webhook's attachment reply. (A bot's `POST .../boosts`
  now broadcasts its boost, as the composer's does.) Rails' fragment cache keeps a message's broadcast render (whose copy
  link has no port) for the page; on a default port the two agree.
- Progress (2026-11-06): the last five -- `POST /users/me/push_subscriptions` (an existing subscription touched, a new
  one created with the request's User-Agent, Push::Subscription's endpoint rules: https, port 443, a permitted push
  service host or its subdomain), `DELETE /users/me/push_subscriptions/:id`, `POST .../:id/test_notifications`,
  `DELETE /searches/clear` and `POST /unfurl_link`. Push and search: 11 of 13 differential scenarios pass; the two
  that differ depend on the network, not the code: Rails resolves a push host and refuses one that does not resolve
  (`eu.notify.windows.com` here), which the port does not look up, and Rails' test notification delivers Web Push
  (the seed's keys are fake, so it answers 500), which the port does not send -- it answers the redirect Rails gives
  after a delivery. Unfurl: `opengraph_unfurl(url)`, a new axum_dsl builtin (`set :rust, :none` stays: the app has no
  Rust of its own); 19 of 19 against Rails on live URLs (GitHub, YouTube, rubyonrails.org, a tweet through
  fxtwitter, pages without og: tags, http, media URLs, loopback, private, IPv6 loopback, unresolvable and malformed
  URLs, a missing `url`), including Rails' dropping of non-ASCII characters on a page that declares no charset. Live
  pages change, so a rerun can differ when a site does.
- Progress (2026-11-06): a page sweep (`test/differential/scenarios/pages.py`: 24 signed-in pages as an administrator
  and as a member, 6 signed-out ones, on the default, custom_styles, restricted and crowd seeds) now passes all 12
  viewer runs. It found and fixed: `account-has-logo` on the involvement, boosts and signed-out pages (sign in, join,
  session transfer), and no leading space in a member's body class; the custom-styles editor and, with room creation
  restricted, the new open and closed room forms answer a member 403; the remove-logo form posts to `?v=`; a boosts
  page for an unreachable message is the 404 page (that route no longer takes `cache: :private`, which cannot hold a
  file's text); an unknown path is a 404 for a signed-out visitor too (`not_found skip: [:authenticate]`, a new
  axum_dsl option: Rails routes before any filter); search results are in creation order, as `.ordered` sorts them.
  `PATCH`/`PUT /account.:id` now take the logo upload and the restrict-room-creation switch beside the name (7
  differential scenarios pass), and every avatar or logo blob carries the analyzed metadata Rails' AnalyzeJob writes.
- Closed 2026-11-07: a newly uploaded account logo's 512/192 PNG variants are made by the first `GET /account/logo` of
  each size, as Rails' `logo_variant(size).processed` makes them (see the 2026-11-07 entry at the end). (Fixed in axum_dsl: narrowing an upload with `if x.nil? ... else x.store(...)
  end` moved it, so a later `x.nil?` was E0382; the match now clones the upload when the body reads it again.)
- Progress (2026-11-06): Web Push. A new message (the composer's and a bot's) now does Room#receive's push_later after
  the answer, in a `later do ... end` block (a new axum_dsl form: a spawned task): Room::MessagePusher's recipients
  (models/push.axum.rb), each sent with `web_push(...)` (a new axum_dsl builtin: RFC 8291 aes128gcm with VAPID, pinned
  to a public address), and a subscription the push service refuses (404, 410) or whose key is not a P-256 point is
  deleted, as WebPush::Pool's invalid-subscription handler does. Found by the bot API's differential runs once
  Rails' push job ran before the rows were compared (the seed's subscriptions have fake keys: Rails deletes them);
  they now settle and match. `VAPID_PRIVATE_KEY` is a plain setting (a `secret:` one would be required to start).
  `GET /users/me/sidebar` outside a Turbo frame now writes the layout's body classes (views/sidebar_page.html).
- Progress (2026-11-06): bot webhooks. A new message (the composer's and a bot's) now runs deliver_webhooks_to_bots
  after the answer: each eligible bot's payload (Webhook#payload: user, room -- `name: null` for a ping -- and message,
  with the recipient's mention removed from the plain text) goes to its webhook with `webhook_post` (a new axum_dsl
  builtin: seven-second timeouts, no proxy), and a text/plain or text/html reply, or the timeout notice, is posted
  back by the bot, broadcast with the renderer's `http://example.org` (a job has no request) and pushed. Checked with
  `test/differential/scenarios/webhooks.py` against a local receiver (`webhook_receiver.py`): the payloads match
  byte for byte in key order (`webhooks_compare.py`), and the reply rows and pages match, for a text reply, an HTML
  reply, no reply and a timeout. axum_dsl's `json_object` now writes nil as null and keeps its keys in order
  (serde_json's `preserve_order`), as Ruby's to_json does; it sorted them. An attachment reply (a known MIME type
  that is not text) is not reproduced. The differential client now sends Turbo's `Accept` (a turbo stream first) on
  its form submissions, as the browser does: MessagesController#create answers an HTML-only one 406.
- Closed (2026-11-06): a Turbo-frame response's head now writes Rails' frame layout's `csrf_meta_tags` (views/turbo_frame.html,
  an empty token as the full layout's); the differential checker compares those metas (token masked) instead of dropping them.
- Progress (2026-11-06): a bot's multipart `attachment` post (curl -F) is the message: the blob, its attachment and the
  filename as the plain text, through axum_dsl's new `request_upload(:attachment)`; a multipart body with no file part is a
  raw body, as Rails' is. Rails' message body is what Action Text stores, not the raw text: a raw bot body, a bot's `PUT`
  and a webhook's reply now go through `action_text_html` (stripped, HTML5-parsed and serialized: `&amp;`, CRLF to LF),
  which was a gap for every bot post with markup, `&` or surrounding whitespace. Its fuzz run against
  `ActionText::Content.new(html).to_html` (`test/differential/fuzz_action_text_html/run.sh`) matches 4,600 of 4,600 random
  bodies; scraper's `deterministic` feature (attributes in source order, as Nokogiri keeps them) was the last difference.
  The attachment's `:thumb` variant is made since 2026-11-07, as for the composer's file post.
- Closed (2026-11-06, browser matrix): `head :forbidden` is axum_dsl's new `head(403)` at all 29 sites: an empty `text/html`
  response that still refreshes the session cookies (`halt(403, "")` sent text/plain and none).
  `/account/users?format=turbo_stream` (and a turbo-stream Accept) answers the page, another format 406, through the new
  `turbo_stream_request?`; the stream's whitespace now matches Rails byte for byte. Before the first run, `/account/logo`
  sends no ETag (`stale?(etag: nil)`; an empty `etag("")` writes none) and `/webmanifest.json` answers Rails' "Campfire"
  manifest instead of a 500. The lean matrix passes on all five seeds (956 cells); the full matrix passes on the four
  small seeds (486 cells); the differential regression matches 127 of 130 (the bot attachment's variant and two push
  cases that need DNS or real Web Push delivery).
- Closed (2026-11-07, image variants): axum_dsl's `image_variant(path, filename, w, h)` runs ImageProcessing::Vips's
  resize_to_limit on libvips (opened at run time; the image installs the reference's `libvips42t64`), and
  models/variant.axum.rb writes what Active Storage writes: the variant record under the variation's digest, the
  analyzed variant blob ("<base>.<format>") and its `image` attachment. The composer's and a bot's attachment get the
  `:thumb` in the post (Message#process_attachment), the logo's `:large`/`:small` and the avatar's `:square` on the first
  GET (`logo_variant`, `avatar_variant`); the borrowed-twin fallbacks are gone from the avatar and logo routes.
  `test/differential/fuzz_image_variant` matches 1,300 of 1,300 random images byte for byte, and the 7 scenarios in
  `scenarios/variants.py` (run with `CANDIDATE_DOCKER=1`, the image's libvips) match rows, checksums and bytes.
  Uploads are now identified as Active Storage identifies them (Marcel 1.1's whole tables, so a JPEG sent as
  application/octet-stream is image/jpeg) and analyzed with the EXIF orientation swap and TIFF/SVG sizes:
  `test/differential/fuzz_identify` matches 3,000 of 3,000. Still not reproduced: previews (a video's or PDF's `:thumb`
  needs ffmpeg or poppler), and a conditional GET of a logo or avatar whose variant does not exist yet makes it before
  answering 304, where Rails' `stale?` answers 304 without processing.
- Closed (2026-11-07, Rails' controller tests): `test/rails_tests/run.sh` runs the reference's 185 controller tests with
  their requests answered by the port (a Rack proxy as the integration app, on the tests' own database); 157 pass. What
  they found and what is now fixed: `update` answers PUT and PATCH (axum_dsl's `also: [:put]`); Rails' optional
  `(.:format)` (`use_layer :format_extension`, so `/boosts/5.turbo_stream` and `/account.873240054` route as Rails
  routes them; the Active Storage filenames are `*filename` globs); query params merge under the form body
  (`set :merge_query_params`); `GET /rooms`, the closed/open room `show` redirects; a signed-in user is redirected away
  from the join page; a `?bot_key=` on a regular page is 403 (`deny_bots`; axum_dsl's `request_query`); sign-out
  redirects to `/` and removes the device's push subscription; a blank unfurl URL is 400; autocomplete escapes names
  and 404s a room the user is not in; the bot API sends no empty Link header (a nil-able computed header is left off);
  and the signed cookies are Rails 7/8's format (`format: :rails7`), so Rails reads the port's session cookie. Still
  failing: assertions on in-process broadcasts, jobs, mocks, raised exceptions and HTTP/DNS stubs (about 23), and
  Active Storage's direct uploads (3), since implemented (below).
- Closed (2026-11-08): the PWA manifest, service worker and QR code (Rails' `allow_unauthenticated_access`) no longer
  write the session cookie back (axum_dsl's `X-Rack-Defaults: unauthenticated` marker), as the WebKit browser matrix
  showed. Active Storage's direct-upload endpoints answer an anonymous caller 401 (ActiveStorageAuthentication).
  A signed-in direct upload was reproduced later (below). Rails'
  controller tests: 158 of 185 pass; the differential regression is still 145 of 147 after the cookie format change.
- Rails' controller tests (2026-11-08): 173 of 185, with the port's broadcasts replayed into Rails' test pubsub
  (axum_dsl's `AXUM_DSL_CABLE_LOG`). The 12 left are listed in test/rails_tests/README.md.
- Closed (2026-11-08), the default-seed browser sample (Firefox and WebKit, light; 1,500 of 1,500 cells):
  - The service worker gets Rails' ETag and `max-age=0, private, must-revalidate`; axum_dsl's rack defaults now tag
    text/javascript, as Rack::ETag does.
  - MessagesController's `layout false, only: :index` keeps the application layout for Turbo-Frame requests to show,
    edit and room-not-found (axum_dsl's `render ..., frame_layout: false`).
  - The user page and profile point their back link at the Referer, as Rails' `link_back` does (axum_dsl's
    `request_referrer`), which WebKit's touch prefetch exposed.
- Closed (2026-11-08): Active Storage direct uploads for a signed-in caller. POST /rails/active_storage/direct_uploads
  creates the blob and answers Rails' JSON (the blob's attributes, `signed_id`, and `direct_upload` with the signed
  `blob_token` URL and its Content-Type header); PUT /rails/active_storage/disk/:token is DiskController#update (204;
  404 for a bad or expired token; 422 for a Content-Type, Content-Length or MD5 mismatch). axum_dsl gained
  `active_storage_key`, `active_storage_direct_upload_url`, `active_storage_disk_upload` and a body
  `active_storage_blob_id`. Checked against Rails: its verifier accepts the port's token and `signed_id`, the port
  accepts a Rails-made upload URL, and Rails' controller tests are 175 of 185 (the 10 left need in-process hooks).
- Closed (2026-11-08): POST /session's rate limit runs after the ban filter, as Rails' callbacks do (ApplicationController's
  reject_banned_ip, then SessionsController's rate_limit), so a banned request is answered 429 uncounted; past 10 in
  3 minutes the answer is render_rejection's sign-in page with a 429. It was a router layer counting every POST, which
  the full matrix at 6 workers showed (auth/sign_in/banned_ip). axum_dsl's `rate_limited?("name", to:, within:)`.
