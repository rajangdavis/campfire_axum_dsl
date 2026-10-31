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
- Closed 2026-10-17: `static "/assets", dir: "public", digest: true, skip: [:authenticate]` in `campfire.axum.rb` serves only the fingerprinted name, and `views/layout.html` writes `href="{{ asset_path "campfire.css" }}"`; the name follows the file's bytes, so no digest is written down here. The generated `ServeDir` sends no `Cache-Control` of its own: the fingerprint only makes a far-future header safe, and setting it is the deployment's job (TODO in the raj tree).
- Closed 2026-10-17: `campfire.axum.rb` declares `use_layer :private_cache, except: ["/assets"]`, so the fingerprint mount no longer carries `private, no-cache`/`Vary: Cookie`; the layer still covers every page. The far-future header itself is still the deployment's job (there is no `cache_control:` keyword yet; TODO in the raj tree).

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
`append` into `messages_room_<id>`. The avatar route landed in C3 (`GET /users/:token/avatar`, section 15). Still
out: `turbo-cable-stream-source`, Action Cable websockets (the harness's `streams`), file attachments beyond the
avatar variant, bots/webhooks, push, the first-run and account pages. Each is a feature of its own: websockets are
the big one for the compiler.

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
- Lacks, variants: the `:thumb` (resize_to_limit 1200x800) a message attachment gets and the `:square` (512x512 webp) an avatar gets.
  Rails creates them (`Message::Attachment#process_attachment`, `User::Avatar#avatar_variant`), so the representation
  redirect (`/rails/active_storage/representations/redirect/...`) and `/users/:token/avatar` have a processed blob to send. Here no
  `active_storage_variant_records` row is written, so the new attachment's representation URL answers 404 and a new avatar still
  shows the initials. Needs `upload.variant(resize_to_limit:, format:)` writing the variant blob, its attachment and the variant record.
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
  candidate `controllers/banned_ips.axum.rb` and `campfire.axum.rb` (`use_layer :rate_limit`).
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
