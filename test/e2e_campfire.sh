#!/bin/sh
# End to end for the Campfire C1 service the DSL generates from campfire.axum.rb, on a temp database that
# db/migrate/001_schema.sql and test/seed.sql build with the sqlite3 command-line tool. It checks what the
# once-campfire-verification contracts (bench/contracts.rb) check: login (302 and a signed cookie), the redirect
# to /session/new without one, the room page's newest 40 message ids and its ETag (304 for its own tag, 200 for
# another), last_room (the cookie a room visit sets and the redirect it drives), the page before message 60, the
# sidebar, search, posting a message with Rails' bracketed form keys (the Turbo Stream, then its three rows, and a
# flat body's 422), the avatar route (a Rails signed_id token, image/webp, exact bytes twice, ffprobe, ETag/304,
# cache headers and 404s), a room the user is not in, /up, the fingerprinted stylesheet, the login's rate limit,
# and that logout kills the cookie. The expected message ids are computed from the database with sqlite3, the way
# contracts.rb does, not written down. Needs curl and sqlite3, plus ruby, sha256sum or shasum for the asset digest;
# the avatar check also needs ffprobe. exit zero only when every check passed.
# usage: sh test/e2e_campfire.sh [CRATE_DIR]      (default /tmp/campfire_axum_dsl-out)
# Build the crate first:  ruby ../axum_dsl/exe/axum_dsl build campfire.axum.rb -o /tmp/campfire_axum_dsl-out
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
dir=${1:-/tmp/campfire_axum_dsl-out}
dir=$(cd "$dir" 2>/dev/null && pwd) || { echo "FAIL: crate directory ${1:-/tmp/campfire_axum_dsl-out} does not exist; build it first"; exit 1; }
host=127.0.0.1
port=8099        # campfire.axum.rb: `set :port, 8099`
name=campfire    # campfire.axum.rb: `server "campfire"` names the crate, so names this binary
base="http://$host:$port"
key=0123456789abcdef0123456789abcdef0123456789
password="campfire-test-pw"    # the password test/seed.sql hashes
email="david@37signals.com"

fail() { echo "FAIL: $1"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
has curl || fail "e2e_campfire.sh speaks HTTP with curl, which is not on PATH"
# The stylesheet is served under its content hash: the first 12 hex digits of its SHA-256, the way the compiler
# computes a `static ... digest: true` mount (examples/assets.axum.rb). ruby is what e2e_assets.sh uses;
# sha256sum and shasum stand in where it is absent.
asset_digest() {
	if has ruby; then
		ruby -rdigest -e 'print Digest::SHA256.hexdigest(File.binread(ARGV[0]))[0, 12]' "$1"
	elif has sha256sum; then
		sha256sum "$1" | cut -c1-12
	elif has shasum; then
		shasum -a 256 "$1" | cut -c1-12
	else
		return 1
	fi
}
css_digest=$(asset_digest "$root/public/campfire.css") || fail "the stylesheet checks compute SHA-256 with ruby, sha256sum or shasum, and none is on PATH"
[ -n "$css_digest" ] || fail "empty digest for $root/public/campfire.css"

# Without the sqlite3 command-line tool (the raj-dev image has none), python3's sqlite3 module stands in for the
# three forms this script uses: `sqlite3 DB <FILE`, `sqlite3 DB SQL` and `sqlite3 -readonly DB SQL`, printing rows
# as the CLI does (columns joined by |, NULL as empty).
if ! has sqlite3; then
	has python3 || fail "e2e_campfire.sh builds its test database with the sqlite3 command-line tool or python3, and neither is on PATH"
	sqlite3() {
		[ "$1" = -readonly ] && shift
		python3 -I -c '
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
if len(sys.argv) > 2:
    for row in db.execute(sys.argv[2]):
        print("|".join("" if v is None else str(v) for v in row))
else:
    db.executescript(sys.stdin.read())
db.commit()
' "$@"
	}
fi

find_bin() {
	for candidate in "${CARGO_TARGET_DIR:-$1/target}/debug/$2" "$1/target/debug/$2"; do
		if [ -x "$candidate" ]; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}
bin=$(find_bin "$dir" "$name") || fail "no $name binary under ${CARGO_TARGET_DIR:-$dir/target}/debug or $dir/target/debug"

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e_campfire.XXXXXX") || exit 1
body="$work/body"
hdr="$work/headers"
err="$work/err"
log="$work/server.log"
db="$work/campfire.sqlite3"
storage="$work/storage/files"
# The real avatar fixture is base64 text so it can live in this repository; the e2e decodes it into
# Active Storage's local Disk layout before the server starts.
avatar_fixture="$here/fixtures/avatar.webp.b64"
# Pinned Rails 8.2 signed_id, minted by the owner on 2026-10-20 in the once-campfire:app image built from
# basecamp/once-campfire@90b3300 (RAILS_ENV=production, SECRET_KEY_BASE=0123456789abcdef0123456789abcdef0123456789,
# user id 2) with:
#   bin/rails runner "puts ActiveRecord::Base.signed_id_verifier.generate(2, purpose: %(user/avatar))"
# Its payload is {"_rails":{"data":2,"pur":"user/avatar"}}. The e2e uses it only when this Ruby has no
# ActiveSupport; with ActiveSupport it mints each token above. Override with FIXED_AVATAR_TOKEN=...
FIXED_AVATAR_TOKEN=${FIXED_AVATAR_TOKEN:-eyJfcmFpbHMiOnsiZGF0YSI6MiwicHVyIjoidXNlci9hdmF0YXIifX0--e7ec9b3f880c3bdd75157af8dc8dcc5b5a896f22a34063545c6df0663e7206c2}
pid=
cleanup() {
	if [ -n "${pid:-}" ]; then
		kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
		pid=
	fi
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

listening() { curl -s -o /dev/null --max-time 2 "$base/up" 2>/dev/null; }

req() {
	method=$1
	path=$2
	shift 2
	status=$(curl -sS --max-time 10 -X "$method" -D "$hdr" -o "$body" -w '%{http_code}' "$@" "$base$path" 2>"$err") || status=000
}

if listening; then
	echo "FAIL: something is already listening on $host:$port, so the service under test cannot bind it."
	echo "      campfire.axum.rb fixes the port with \`set :port, 8099\`, and this test has no other."
	exit 1
fi

# The database: the schema migration, then the seed. The server applies the same (IF NOT EXISTS) migration as it
# starts, which must leave these tables as they are.
sqlite3 "$db" <"$root/db/migrate/001_schema.sql" || fail "sqlite3 could not load db/migrate/001_schema.sql (does this sqlite3 have FTS5?)"
sqlite3 "$db" <"$here/seed.sql" || fail "sqlite3 could not load test/seed.sql"

# Jason's processed avatar: the seed names variant blob key `jasonavatarvariant`, whose Active Storage path is
# storage/files/ja/so/jasonavatarvariant.
mkdir -p "$storage/ja/so" || fail "could not create the avatar storage directory"
ruby -e 'File.binwrite(ARGV[1], File.read(ARGV[0]).strip.unpack1("m0"))' "$avatar_fixture" "$storage/ja/so/jasonavatarvariant" \
	|| fail "could not decode $avatar_fixture with Ruby"

# ids SQL: the ids a query returns, in order, on one line.
ids() { sqlite3 -readonly "$db" "$1" | tr '\n' ' ' | sed 's/ *$//'; }
# page_ids: the data-message-id values of the last body, in order, on one line.
page_ids() { grep -o 'data-message-id="[0-9]*"' "$body" | grep -o '[0-9][0-9]*' | tr '\n' ' ' | sed 's/ *$//'; }

passed=0
failed=0
ok() {
	passed=$((passed + 1))
	echo "ok: $1"
}
bad() {
	failed=$((failed + 1))
	echo "FAIL: $1"
}

# status_is LABEL CODE
status_is() {
	if [ "$status" = "$2" ]; then ok "$1 -> $status"; else bad "$1: HTTP $status, wanted $2"; sed 's/^/      /' "$err" 2>/dev/null || true; fi
}

# content_type_is LABEL TYPE: the last req's Content-Type is that type (a charset suffix allowed).
content_type_is() {
	ctype=$(sed -n 's/^[Cc]ontent-[Tt]ype: *//p' "$hdr" | tr -d '\r' | head -n 1)
	case "$ctype" in
	"$2" | "$2;"*) ok "$1 -> $ctype" ;;
	*) bad "$1: content type [$ctype], wanted [$2]" ;;
	esac
}

# redirects LABEL LOCATION: the last req answered a redirect to that Location.
redirects() {
	location=$(sed -n 's/^[Ll]ocation: *//p' "$hdr" | tr -d '\r' | head -n 1)
	case "$status" in
	301 | 302 | 303 | 307 | 308)
		if [ "$location" = "$2" ]; then
			ok "$1 -> $status, Location $location"
			return 0
		fi
		;;
	esac
	bad "$1: HTTP $status with Location [$location], wanted a redirect to [$2]"
}

# has_text LABEL TEXT: the last body holds that text literally.
has_text() {
	if grep -Fq -- "$2" "$body"; then ok "$1"; else bad "$1: body lacks [$2]"; fi
}
lacks_text() {
	if grep -Fq -- "$2" "$body"; then bad "$1: body holds [$2]"; else ok "$1"; fi
}

# same_ids LABEL EXPECTED: the last body's data-message-id list equals the expected one.
same_ids() {
	got=$(page_ids)
	if [ "$got" = "$2" ] && [ -n "$got" ]; then
		ok "$1: $(echo "$got" | wc -w | tr -d ' ') message ids, as the database says"
	else
		bad "$1: ids differ from the seed SQL"
		echo "      got:      [$got]"
		echo "      expected: [$2]"
	fi
}

login_cookie() {
	sed -n 's/^[Ss]et-[Cc]ookie: *\(session_token=[^;]*\).*/\1/p' "$hdr" | tr -d '\r' | head -n 1
}

# A Rails 8 signed_id. First choice is real ActiveSupport (MessageVerifier + KeyGenerator), so the e2e is
# checking Rails' format rather than reimplementing it. If that gem is not in this Ruby, FIXED_AVATAR_TOKEN
# must be a token minted by the pinned Rails 8.2 reference image with this script's SECRET_KEY_BASE, id 2
# and purpose user/avatar; it is only the happy path: wrong-purpose and unknown-id checks need generation.
active_support_available() {
	ruby -e 'require "active_support"; require "active_support/key_generator"; require "active_support/message_verifier"' >/dev/null 2>&1
}

avatar_token() {
	if active_support_available; then
		ruby -rjson -ropenssl -ractive_support -ractive_support/key_generator -ractive_support/message_verifier -e '
			secret, id, purpose = ARGV
			# A Rails 7.1+ app runs with these defaults (load_defaults 7.1/7.0); a bare require leaves them unset.
			ActiveSupport::Messages::Metadata.use_message_serializer_for_metadata = true
			ActiveSupport::KeyGenerator.hash_digest_class = OpenSSL::Digest::SHA256
			key = ActiveSupport::KeyGenerator.new(secret, iterations: 1000).generate_key("active_record/signed_id", 64)
			verifier = ActiveSupport::MessageVerifier.new(key, digest: "SHA256", serializer: JSON, url_safe: true)
			print verifier.generate(Integer(id), purpose: purpose)
		' "$key" "$1" "${2:-user/avatar}"
	elif [ -n "$FIXED_AVATAR_TOKEN" ]; then
		printf '%s' "$FIXED_AVATAR_TOKEN"
	else
		return 1
	fi
}

DATABASE_PATH="$db" SECRET_KEY_BASE="$key" ACTIVE_STORAGE_PATH="$storage" setsid sh -c "cd '$dir' && exec '$bin'" >>"$log" 2>&1 &
pid=$!
i=0
until listening; do
	i=$((i + 1))
	if [ "$i" -gt 100 ]; then
		echo "FAIL: $host:$port did not accept a connection within 10 s"
		sed 's/^/      /' "$log" 2>/dev/null || true
		exit 1
	fi
	if ! kill -0 "$pid" 2>/dev/null; then
		echo "FAIL: $bin exited before it accepted a connection on $host:$port"
		sed 's/^/      /' "$log" 2>/dev/null || true
		exit 1
	fi
	sleep 0.1
done

# --- login -------------------------------------------------------------------------------------------------
req GET /session/new
status_is "GET /session/new" 200
has_text "the form posts to /session" "action=\"/session\""
has_text "the form has email_address" "name=\"email_address\""
has_text "the form has password" "name=\"password\""

req POST /session -H "Sec-Fetch-Site: same-origin" --data-urlencode "email_address=$email" --data-urlencode "password=wrong"
status_is "POST /session with a wrong password" 401
has_text "the refused login is the real form" "action=\"/session\""
lacks_text "the refused login is not the inline apology" "Too many requests or unauthorized."
if grep -qi '^set-cookie:' "$hdr"; then bad "a refused login set a cookie"; else ok "a refused login sets no cookie"; fi
req POST /session -H "Sec-Fetch-Site: same-origin" --data-urlencode "email_address=nobody@example.com" --data-urlencode "password=$password"
status_is "POST /session with an unknown email" 401

req POST /session -H "Sec-Fetch-Site: same-origin" --data-urlencode "email_address=$email" --data-urlencode "password=$password"
status_is "POST /session logs in with a 302" 302
redirects_loc=$(sed -n 's/^[Ll]ocation: *//p' "$hdr" | tr -d '\r' | head -n 1)
if [ "$redirects_loc" = "/" ]; then ok "the login redirects to /"; else bad "the login redirects to [$redirects_loc], wanted /"; fi
cookie=$(login_cookie)
if [ -n "$cookie" ]; then ok "the login sets a session_token cookie"; else bad "no session_token cookie"; echo "      headers:"; sed 's/^/      /' "$hdr"; fail "no cookie to carry on with"; fi

# a deactivated user cannot sign in (status 1)
sqlite3 "$db" "UPDATE users SET status = 1 WHERE id = 2"
req POST /session -H "Sec-Fetch-Site: same-origin" --data-urlencode "email_address=jason@37signals.com" --data-urlencode "password=$password"
status_is "a deactivated user cannot log in" 401
sqlite3 "$db" "UPDATE users SET status = 0 WHERE id = 2"

# --- avatar -------------------------------------------------------------------------------------------------
avatar=$(avatar_token 2) || fail "could not mint a Rails signed_id: ActiveSupport is absent and FIXED_AVATAR_TOKEN is empty"
req GET "/users/$avatar/avatar" -H "Cookie: $cookie"
status_is "GET /users/:token/avatar" 200
content_type_is "the avatar is image/webp" image/webp
avatar_bytes=$(wc -c <"$body" | tr -d ' ')
if [ "$avatar_bytes" -gt 100 ]; then ok "the avatar is more than 100 bytes ($avatar_bytes)"; else bad "the avatar is only $avatar_bytes bytes"; fi
cp "$body" "$work/avatar.first"
req GET "/users/$avatar/avatar" -H "Cookie: $cookie"
if cmp -s "$body" "$work/avatar.first"; then ok "the avatar bytes are identical on a second request"; else bad "the avatar bytes changed between requests"; fi
if [ "$(wc -c <"$body" | tr -d ' ')" = "$avatar_bytes" ]; then ok "the avatar body is the same size twice"; else bad "the avatar body size changed"; fi
avatar_etag=$(sed -n 's/^[Ee][Tt]ag: *//p' "$hdr" | tr -d '\r' | head -n 1)
case "$avatar_etag" in
'W/"avatar-'*) ok "the avatar carries a weak avatar ETag: $avatar_etag" ;;
*) bad "the avatar ETag shape is [$avatar_etag], wanted a weak avatar tag" ;;
esac
avatar_cache=$(sed -n 's/^[Cc]ache-[Cc]ontrol: *//p' "$hdr" | tr -d '\r' | head -n 1)
case "$avatar_cache" in
*public*max-age=1800*stale-while-revalidate=604800*) ok "the avatar is publicly cacheable for 30 minutes with a one-week stale window" ;;
*) bad "the avatar Cache-Control is [$avatar_cache]" ;;
esac
: >"$body"
req GET "/users/$avatar/avatar" -H "Cookie: $cookie" -H "If-None-Match: $avatar_etag"
status_is "the avatar with its own ETag" 304
if [ -s "$body" ]; then bad "the avatar 304 carries a body"; else ok "the avatar 304 has no body"; fi
req GET "/users/$avatar/avatar" -H "Cookie: $cookie"
if has ffprobe; then
	if ffprobe -v error -count_frames -show_entries stream=width,height,nb_read_frames -of json "$body" >"$work/avatar.json" 2>"$work/avatar.err" &&
		ruby -rjson -e 's = JSON.parse(File.read(ARGV[0]))["streams"]; exit(s.any? { |x| x["width"].to_i > 0 && x["height"].to_i > 0 && x["nb_read_frames"].to_i > 0 } ? 0 : 1)' "$work/avatar.json"; then
		ok "ffprobe decodes the avatar and finds a frame"
	else
		bad "ffprobe could not decode the avatar"
		sed 's/^/      /' "$work/avatar.err" 2>/dev/null || true
	fi
else
	bad "ffprobe is not on PATH, so the avatar cannot be proven a real image"
fi
req GET "/users/${avatar}x/avatar" -H "Cookie: $cookie"
status_is "GET /users/:token/avatar with a tampered token" 404
req GET "/users/not-a-token/avatar" -H "Cookie: $cookie"
status_is "GET /users/:token/avatar with a junk token" 404
if active_support_available; then
	wrong_purpose=$(avatar_token 2 "user/not-avatar")
	req GET "/users/$wrong_purpose/avatar" -H "Cookie: $cookie"
	status_is "GET /users/:token/avatar with a wrong purpose" 404
	unknown=$(avatar_token 999)
	req GET "/users/$unknown/avatar" -H "Cookie: $cookie"
	status_is "GET /users/:token/avatar for a missing user" 404
fi

# --- no cookie ---------------------------------------------------------------------------------------------
req GET /rooms/1
redirects "GET /rooms/1 without a cookie" /session/new
req GET /users/me/sidebar
redirects "GET /users/me/sidebar without a cookie" /session/new
req GET "/searches?q=coffee"
redirects "GET /searches without a cookie" /session/new
req GET /rooms/1 -H "Cookie: ${cookie}x"
redirects "GET /rooms/1 with a tampered cookie" /session/new

# --- the room page -----------------------------------------------------------------------------------------
req GET / -H "Cookie: $cookie"
redirects "GET / goes to the first room" /rooms/1

sqlite3 "$db" "UPDATE memberships SET unread_at = '2026-01-01 00:00:00' WHERE room_id = 1 AND user_id = (SELECT id FROM users WHERE email_address = '$email')"
req GET /rooms/1 -H "Cookie: $cookie"
status_is "GET /rooms/1" 200
if [ "$(ids "SELECT COUNT(*) FROM memberships WHERE room_id = 1 AND user_id = (SELECT id FROM users WHERE email_address = '$email') AND unread_at IS NULL")" = "1" ]; then ok "a room visit clears unread_at"; else bad "a room visit left unread_at set"; fi
same_ids "room_show" "$(ids "SELECT id FROM (SELECT id, created_at FROM messages WHERE room_id=1 ORDER BY created_at DESC LIMIT 40) ORDER BY created_at")"
has_text "the page is a full document (doctype)" "<!doctype html>"
has_text "the page is a full document (closing tag)" "</html>"
has_text "the messages container id" "id=\"messages_room_1\""
has_text "message 90 carries id=message_90" "id=\"message_90\""
has_text "the layout links the fingerprinted stylesheet" "href=\"/assets/campfire-$css_digest.css\""
has_text "a creator's name shows" "David Heinemeier"
has_text "a body with an ampersand is escaped" "Tom &amp; Jerry"
has_text "the rich-text markup is sanitised and rendered" "class=\"trix-content\""
lacks_text "the trix markup is not escaped as text" "&lt;div class=&quot;trix-content&quot;&gt;"

# --- the room's ETag ---------------------------------------------------------------------------------------
req GET /rooms/1 -H "Cookie: $cookie"
status_is "GET /rooms/1 for its ETag" 200
room_etag=$(sed -n 's/^[Ee][Tt]ag: *//p' "$hdr" | tr -d '\r' | head -n 1)
if [ -n "$room_etag" ]; then ok "the room page carries an ETag: $room_etag"; else bad "the room page has no ETag header"; fi
case "$room_etag" in
'"room-'*) ok "the ETag is a quoted room tag" ;;
*) bad "the ETag shape is [$room_etag], wanted a quoted room tag" ;;
esac
: > "$body"
req GET /rooms/1 -H "Cookie: $cookie" -H "If-None-Match: $room_etag"
status_is "the room page with its own ETag in If-None-Match" 304
if [ -s "$body" ]; then bad "the 304 carries a body"; else ok "the 304 has no body"; fi
req GET /rooms/1 -H "Cookie: $cookie" -H 'If-None-Match: "room-stale"'
status_is "the room page with a different ETag" 200
has_text "the 200 for a different ETag is the full page" "id=\"messages_room_1\""
room_cache=$(sed -n 's/^[Cc]ache-[Cc]ontrol: *//p' "$hdr" | tr -d '\r' | head -n 1)
case "$room_cache" in
*private*no-cache*) ok "the room page is Cache-Control: private, no-cache" ;;
*) bad "the room page Cache-Control is [$room_cache]" ;;
esac
room_vary=$(sed -n 's/^[Vv]ary: *//p' "$hdr" | tr -d '\r' | head -n 1)
case "$room_vary" in
*Cookie*) ok "the room page varies on Cookie" ;;
*) bad "the room page Vary is [$room_vary]" ;;
esac

# --- last_room ---------------------------------------------------------------------------------------------
req GET /rooms/2 -H "Cookie: $cookie"
status_is "GET /rooms/2, a room david is in" 200
last_room_cookie=$(sed -n 's/^[Ss]et-[Cc]ookie: *\(last_room=[^;]*\).*/\1/p' "$hdr" | tr -d '\r' | head -n 1)
if [ "$last_room_cookie" = "last_room=2" ]; then ok "a room visit sets last_room to that room"; else bad "the last_room cookie is [$last_room_cookie], wanted [last_room=2]"; fi
req GET / -H "Cookie: $cookie; $last_room_cookie"
redirects "GET / goes to the room last visited" /rooms/2
req GET / -H "Cookie: $cookie"
redirects "GET / with no last_room cookie goes to the first room" /rooms/1
req GET / -H "Cookie: $cookie; last_room=3"
redirects "a last_room david is not in falls back to the first room" /rooms/1
req GET / -H "Cookie: $cookie; last_room=999"
redirects "a last_room that does not exist falls back to the first room" /rooms/1

# --- the earlier-messages page -----------------------------------------------------------------------------
sqlite3 "$db" "UPDATE memberships SET unread_at = '2026-01-01 00:00:00' WHERE room_id = 1 AND user_id = (SELECT id FROM users WHERE email_address = '$email')"
req GET "/rooms/1/messages?before=60" -H "Cookie: $cookie"
status_is "GET /rooms/1/messages?before=60" 200
if [ "$(ids "SELECT COUNT(*) FROM memberships WHERE room_id = 1 AND user_id = (SELECT id FROM users WHERE email_address = '$email') AND unread_at IS NULL")" = "1" ]; then ok "the earlier-messages page clears unread_at"; else bad "the earlier-messages page left unread_at set"; fi
same_ids "messages_page" "$(ids "SELECT id FROM (SELECT id, created_at FROM messages WHERE room_id=1 AND created_at < (SELECT created_at FROM messages WHERE id=60) ORDER BY created_at DESC LIMIT 40) ORDER BY created_at")"
lacks_text "the fragment has no layout" "<html"
req GET "/rooms/1/messages?before=1" -H "Cookie: $cookie"
status_is "no earlier messages" 204

# --- the sidebar -------------------------------------------------------------------------------------------
req GET /users/me/sidebar -H "Cookie: $cookie"
status_is "GET /users/me/sidebar" 200
has_text "the sidebar has shared_rooms" "shared_rooms"
has_text "the sidebar names Watercooler" ">Watercooler<"
has_text "the sidebar escapes Sales & Support" ">Sales &amp; Support<"
has_text "the sidebar links the room" "href=\"/rooms/1\""
lacks_text "the invisible room is not listed" "Quiet Corner"
lacks_text "a room david is not in is not listed" "Skunkworks"
has_text "the sidebar is a full document" "</html>"

# --- search ------------------------------------------------------------------------------------------------
req GET "/searches?q=coffee" -H "Cookie: $cookie"
status_is "GET /searches?q=coffee" 200
same_ids "search" "$(ids "SELECT id FROM (SELECT m.id AS id FROM messages m JOIN message_search_index idx ON idx.rowid=m.id JOIN memberships mm ON mm.room_id=m.room_id JOIN users u ON u.id=mm.user_id WHERE u.email_address='$email' AND idx.body MATCH 'coffee' ORDER BY m.id DESC LIMIT 100) ORDER BY id")"
lacks_text "search leaves out the room david is not in" "message_111"
has_text "the search page is a full document" "</html>"
req GET "/searches?q=%22%3B%20coffee%20--" -H "Cookie: $cookie"
status_is "punctuation in q is stripped, not passed to FTS" 200
req GET "/searches?q=" -H "Cookie: $cookie"
status_is "a blank q" 200
lacks_text "a blank q finds nothing" "data-message-id"

# --- a room david is not in --------------------------------------------------------------------------------
req GET /rooms/3 -H "Cookie: $cookie"
redirects "a room david is not in" /
req GET "/rooms/3/messages?before=113" -H "Cookie: $cookie"
redirects "that room's earlier messages" /
req GET /rooms/999 -H "Cookie: $cookie"
redirects "a room that does not exist" /

# --- health and the stylesheet -----------------------------------------------------------------------------
req GET /up
status_is "GET /up" 200
has_text "/up is green" "background-color: green"
req GET "/assets/campfire-$css_digest.css"
status_is "GET /assets/campfire-$css_digest.css" 200
if grep -i '^content-type:' "$hdr" | grep -qi 'text/css'; then ok "the fingerprinted stylesheet is text/css"; else bad "the fingerprinted stylesheet is not text/css"; fi
if cmp -s "$body" "$root/public/campfire.css"; then ok "the fingerprinted stylesheet's bytes are the file's"; else bad "the fingerprinted stylesheet's bytes differ from public/campfire.css"; fi
if sed -n 's/^[Cc]ache-[Cc]ontrol: *//p' "$hdr" | tr -d '\r' | grep -qi 'private, no-cache'; then bad "the fingerprinted stylesheet still carries the layer's private, no-cache"; else ok "the fingerprinted stylesheet is exempt from private_cache"; fi
req GET /assets/campfire.css
status_is "the undigested stylesheet URL" 404

# --- posting a message --------------------------------------------------------------------------------------
before_messages=$(ids "SELECT COUNT(*) FROM messages")
before_rich=$(ids "SELECT COUNT(*) FROM action_text_rich_texts")
before_index=$(ids "SELECT COUNT(*) FROM message_search_index")

posted="e2e stream message"
client_id="e2e-client-message-1"
req POST /rooms/1/messages -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "message%5Bbody%5D=$posted" --data-urlencode "message%5Bclient_message_id%5D=$client_id"
status_is "POST /rooms/1/messages" 200
content_type_is "the stream is a Turbo Stream" "text/vnd.turbo-stream.html"
has_text "the stream appends to the room" "<turbo-stream action=\"append\" target=\"messages_room_1\">"
has_text "the stream carries a template" "<template>"
has_text "the stream carries the submitted text" "$posted"
new_message_id=$(ids "SELECT MAX(id) FROM messages")
if [ "$(ids "SELECT COUNT(*) FROM messages")" = "$((before_messages + 1))" ]; then ok "the message row was inserted"; else bad "the message count did not grow by one"; fi
if [ "$(ids "SELECT COUNT(*) FROM action_text_rich_texts WHERE record_type='Message' AND record_id=$new_message_id AND name='body'")" = "1" ]; then ok "the rich text row was inserted"; else bad "no rich text row for message $new_message_id"; fi
if [ "$(ids "SELECT COUNT(*) FROM message_search_index WHERE rowid=$new_message_id")" = "1" ]; then ok "the FTS row was inserted"; else bad "no FTS row for message $new_message_id"; fi
if [ "$(ids "SELECT client_message_id FROM messages WHERE id=$new_message_id")" = "$client_id" ]; then ok "the bracketed client_message_id reached the row"; else bad "the client_message_id row is [$(ids "SELECT client_message_id FROM messages WHERE id=$new_message_id")]"; fi

req GET /rooms/1 -H "Cookie: $cookie"
status_is "GET /rooms/1 after the post" 200
has_text "the room page shows the new message" "id=\"message_$new_message_id\""
new_etag=$(sed -n 's/^[Ee][Tt]ag: *//p' "$hdr" | tr -d '\r' | head -n 1)
if [ -n "$new_etag" ] && [ "$new_etag" != "$room_etag" ]; then ok "the ETag changes when a message arrives: $new_etag"; else bad "the ETag after the post is [$new_etag], wanted a change from [$room_etag]"; fi

req POST /rooms/1/messages -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "body=flat wire name"
status_is "a flat body does not satisfy message[body]" 422
req POST /rooms/1/messages --data-urlencode "message%5Bbody%5D=no cookie"
redirects "POST /rooms/1/messages without a cookie" /session/new
req POST /rooms/3/messages -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "message%5Bbody%5D=not a member"
redirects "POST to a room david is not in" /
after_messages=$(ids "SELECT COUNT(*) FROM messages")
after_rich=$(ids "SELECT COUNT(*) FROM action_text_rich_texts")
after_index=$(ids "SELECT COUNT(*) FROM message_search_index")
if [ "$after_messages" = "$((before_messages + 1))" ] && [ "$after_rich" = "$((before_rich + 1))" ] && [ "$after_index" = "$((before_index + 1))" ]; then
	ok "the refused posts inserted nothing"
else
	bad "the refused posts changed the database"
fi

# --- logout ------------------------------------------------------------------------------------------------
req DELETE /session -H "Cookie: $cookie"
redirects "the logout goes to /session/new" "/session/new"
if grep -i '^set-cookie: session_token=;' "$hdr" >/dev/null; then ok "the logout clears the cookie"; else bad "the logout did not clear the cookie"; fi
req GET /rooms/1 -H "Cookie: $cookie"
redirects "the old cookie no longer works (its session row is gone)" /session/new

# --- the login's rate limit --------------------------------------------------------------------------------
# The login has a rate limit (per: 60, burst: 20, path: /session): a wrong password costs no bcrypt, and a burst
# past the bucket must answer 429 somewhere. The loop sends more than twice the burst (41), so a 60 s window
# boundary can split it but cannot put every part under the limit (30 could). GET /session/new is outside that
# path and still answers.
limited=0
i=0
while [ "$i" -lt 41 ]; do
	i=$((i + 1))
	req POST /session -H "Sec-Fetch-Site: same-origin" --data-urlencode "email_address=nobody@example.com" --data-urlencode "password=wrong"
	if [ "$status" = "429" ]; then limited=$((limited + 1)); fi
done
if [ "$limited" -gt 0 ]; then ok "the login is rate limited: $limited of 41 posts answered 429"; else bad "none of the 41 posts to /session answered 429"; fi
req GET /session/new
status_is "GET /session/new after the burst" 200

if [ "$failed" -ne 0 ]; then
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: login (302, cookie), the redirect without one, room_show ids and ETag, last_room, messages_page ids, the sidebar, search, posting a message, the avatar route, rooms david is not in, /up, the fingerprinted stylesheet, the login rate limit, logout"
