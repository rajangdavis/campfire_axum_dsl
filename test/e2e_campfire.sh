#!/bin/sh
# End to end for the Campfire C1 service the DSL generates from campfire.axum.rb, on a temp database that
# db/migrate/001_schema.sql and test/seed.sql build with the sqlite3 command-line tool. It checks what the
# once-campfire-verification contracts (bench/contracts.rb) check: login (302 and a signed cookie), the redirect
# to /session/new without one, the room page's newest 40 message ids and its ETag (304 for its own tag, 200 for
# another), last_room (the cookie a room visit sets and the redirect it drives), the page before message 60, the
# sidebar, search, posting a message with Rails' bracketed form keys (the Turbo Stream, then its three rows, and a
# flat body's 422), the avatar route (a Rails signed_id token, image/webp, exact bytes twice, ffprobe, ETag/304,
# cache headers and 404s), a room the user is not in, /up, the fingerprinted stylesheet, the login's rate limit,
# and that logout kills the cookie, and the removal of stored files as the code does it today (the regression bar for has_one_attached):
# DELETE of the avatar, the account logo upload, replacement and DELETE (a member refused), and deleting a message with an attachment, each
# checked for the attachment, blob and variant rows, the files left on disk and the touch. The expected message ids are computed from the database with sqlite3, the way
# contracts.rb does, not written down. Needs curl and sqlite3, plus ruby, sha256sum or shasum for the asset digest;
# the avatar check also needs ffprobe; the Action Cable check needs node. exit zero only when every check passed.
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
# The stylesheet is served under Propshaft's digest, the way the compiler computes a `static ... digest: true`
# mount: the first 8 hex digits of SHA-1 over the file's bytes and then "1.0" (the assets version), after the bytes
# of any file its CSS refers to. campfire.css and _reset.css refer to none, so the file is all there is to hash.
# ruby is what e2e_assets.sh uses; sha1sum and shasum stand in where it is absent.
asset_digest() {
	if has ruby; then
		ruby -rdigest -e 'print Digest::SHA1.hexdigest(File.binread(ARGV[0]) + "1.0")[0, 8]' "$1"
	elif has sha1sum; then
		{ cat "$1"; printf 1.0; } | sha1sum | cut -c1-8
	elif has shasum; then
		{ cat "$1"; printf 1.0; } | shasum -a 1 | cut -c1-8
	else
		return 1
	fi
}
css_digest=$(asset_digest "$root/public/campfire.css") || fail "the stylesheet checks compute SHA-1 with ruby, sha1sum or shasum, and none is on PATH"
[ -n "$css_digest" ] || fail "empty digest for $root/public/campfire.css"
# The parity layout links Rails' stylesheets (public/_reset.css ... utilities.css) and no longer campfire.css.
reset_digest=$(asset_digest "$root/public/_reset.css") || fail "cannot digest $root/public/_reset.css"

# Without the sqlite3 command-line tool (the raj-dev image has none), python3's sqlite3 module stands in for the
# three forms this script uses: `sqlite3 DB <FILE`, `sqlite3 DB SQL` and `sqlite3 -readonly DB SQL`, printing rows
# as the CLI does (columns joined by |, NULL as empty). A SQL argument may hold several statements, so it is split
# on complete statements and each one's rows are printed.
if ! has sqlite3; then
	has python3 || fail "e2e_campfire.sh builds its test database with the sqlite3 command-line tool or python3, and neither is on PATH"
	sqlite3() {
		[ "$1" = -readonly ] && shift
		python3 -I -c '
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
def run(sql):
    cursor = db.execute(sql)
    if cursor.description:
        for row in cursor:
            print("|".join("" if v is None else str(v) for v in row))
if len(sys.argv) > 2:
    statement = ""
    for ch in sys.argv[2]:
        statement += ch
        if ch == ";" and sqlite3.complete_statement(statement):
            run(statement)
            statement = ""
    if statement.strip():
        run(statement)
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
# The same, for user id 1 (David), the seed's no-avatar user the initials/bot fallback checks fetch.
FIXED_AVATAR_TOKEN_1=${FIXED_AVATAR_TOKEN_1:-eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--36c83701cb26fb950956d9b7f78d21c9053b89ecc71ddaa5965727572b8281b9}
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
# Each failure is kept as well, and listed again at the end: a long run's middle may be cut from a hook's output.
failures=""
bad() {
	failed=$((failed + 1))
	failures="$failures
  $1"
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

# redirects LABEL PATH: the last req answered a redirect to that path as an absolute URL on this host (Rails' redirect_to).
redirects() {
	location=$(sed -n 's/^[Ll]ocation: *//p' "$hdr" | tr -d '\r' | head -n 1)
	case "$status" in
	301 | 302 | 303 | 307 | 308)
		if [ "$location" = "$base$2" ]; then
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

# header_value NAME: the last response's first header with that name, trimmed.
header_value() {
	grep -i "^$1:" "$hdr" 2>/dev/null | head -1 | sed 's/^[^:]*: *//' | tr -d '\r'
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
		if [ "$1" = 1 ] && [ -n "${FIXED_AVATAR_TOKEN_1:-}" ]; then
			printf '%s' "$FIXED_AVATAR_TOKEN_1"
		else
			printf '%s' "$FIXED_AVATAR_TOKEN"
		fi
	else
		return 1
	fi
}

# A Rails 8 signed_id for `User#transfer_id` (app/models/user/transferable.rb:5-8: signed_id(purpose: :transfer,
# expires_in: 4.hours)). The key is ActiveSupport::KeyGenerator's PBKDF2-HMAC-SHA256 over SECRET_KEY_BASE with the
# "active_record/signed_id" salt and 1000 iterations, 64 bytes; the message is Rails' url-safe unpadded Base64 of the
# JSON `_rails` envelope, `--`, and a lower-case hex HMAC-SHA256. `expires_in` is seconds from now: 14400 is the app's
# four hours, -60 an expired link.
transfer_token() {
	# `pack("m0")` is strict Base64 without newlines; base64 is no longer a default gem, and this needs only
	# the alphabet swap and the padding removal Rails' url_safe: true writes.
	ruby -rjson -ropenssl -e '
		secret, id, expires_in = ARGV
		key = OpenSSL::KDF.pbkdf2_hmac(secret, salt: "active_record/signed_id", iterations: 1000, length: 64, hash: OpenSSL::Digest.new("SHA256"))
		exp = (Time.now.utc + Integer(expires_in)).strftime("%Y-%m-%dT%H:%M:%S.%LZ")
		payload = JSON.generate("_rails" => { "data" => Integer(id), "exp" => exp, "pur" => "user/transfer" })
		encoded = [payload].pack("m0").tr("+/", "-_").delete("=")
		digest = OpenSSL::HMAC.hexdigest("SHA256", key, encoded)
		print encoded + "--" + digest
	' "$key" "$1" "${2:-14400}"
}

DATABASE_PATH="$db" SECRET_KEY_BASE="$key" ACTIVE_STORAGE_PATH="$storage" GIT_REVISION=parity setsid sh -c "cd '$dir' && exec '$bin'" >>"$log" 2>&1 &
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
has_text "the form posts to /session (absolute, as Rails' session_url)" "/session\" accept-charset="
has_text "the form has email_address" "name=\"email_address\""
has_text "the form has password" "name=\"password\""
# Rails' layout renders a freshly masked CSRF token, so the page's Rack::ETag never repeats and the reload Turbo makes
# after the refused login's 401 is a 200 (a 304 left auth/sign_in/error waiting on its stylesheets on the VM).
page_etag=$(sed -n 's/^[Ee][Tt]ag: *//p' "$hdr" | tr -d '\r' | head -n 1)
req GET /session/new -H "If-None-Match: $page_etag"
status_is "GET /session/new with its own ETag in If-None-Match (a full page's ETag never repeats)" 200

req POST /session -H "Sec-Fetch-Site: same-origin" --data-urlencode "email_address=$email" --data-urlencode "password=wrong"
status_is "POST /session with a wrong password" 401
has_text "the refused login is the real form" "/session\" accept-charset="
has_text "the refused login carries Rails' flash.now alert" "role=\"alert\" aria-atomic=\"true\">Too many requests or unauthorized.</span>"
# Rails' 401 page writes the _campfire_session cookie like any rendered page; what must not come is a session_token.
if grep -qi '^set-cookie: *session_token=' "$hdr"; then bad "a refused login set a session_token"; else ok "a refused login sets no session_token"; fi
# The refused login as a browser loads it (auth/sign_in/error hung on its stylesheets in VM run 2026-10-28T23-06): the
# form's cookies, the 401 with the cookies it sets, then every stylesheet the 401 page links, six at a time on kept-alive
# connections, as Chromium fetches them when Turbo swaps the head in.
jar="$work/login.jar"
curl -sS --max-time 10 -c "$jar" -o "$body" "$base/session/new" 2>"$err"
curl -sS --max-time 10 -b "$jar" -c "$jar" -D "$hdr" -o "$body" -H "Sec-Fetch-Site: same-origin" \
	--data-urlencode "email_address=$email" --data-urlencode "password=wrong" "$base/session" 2>"$err"
grep -o 'rel="stylesheet" href="/assets/[^"]*"' "$body" | sed 's|.*href="||; s|"$||' \
	| while read -r sheet; do printf 'url = "%s%s"\noutput = "/dev/null"\n' "$base" "$sheet"; done >"$work/sheets.cfg"
if [ ! -s "$work/sheets.cfg" ]; then
	bad "the refused login page links no stylesheets"
elif codes=$(curl -sS --max-time 10 --parallel --parallel-max 6 -b "$jar" -H "Accept-Encoding: gzip" -w '%{http_code}\n' -K "$work/sheets.cfg" 2>"$err"); then
	if printf '%s\n' "$codes" | grep -qv '^200$'; then bad "a stylesheet after a refused login was not a 200: $(printf '%s' "$codes" | tr '\n' ' ')"; else ok "after a refused login, all $(printf '%s\n' "$codes" | wc -l | tr -d ' ') stylesheets load"; fi
else
	bad "the stylesheets after a refused login did not all load within 10s: $(cat "$err")"
fi
req POST /session -H "Sec-Fetch-Site: same-origin" --data-urlencode "email_address=nobody@example.com" --data-urlencode "password=$password"
status_is "POST /session with an unknown email" 401

req POST /session -H "Sec-Fetch-Site: same-origin" --data-urlencode "email_address=$email" --data-urlencode "password=$password"
status_is "POST /session logs in with a 302" 302
redirects_loc=$(sed -n 's/^[Ll]ocation: *//p' "$hdr" | tr -d '\r' | head -n 1)
if [ "$redirects_loc" = "$base/" ]; then ok "the login redirects to $base/"; else bad "the login redirects to [$redirects_loc], wanted $base/"; fi
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
# A file response names x-version/x-rev but gets no HTML security headers, as Rails' default headers do.
for sec in x-frame-options x-content-type-options x-xss-protection x-permitted-cross-domain-policies referrer-policy; do
	if [ -z "$(header_value "$sec")" ]; then ok "the avatar has no $sec"; else bad "the avatar carries $sec [$(header_value "$sec")]"; fi
done
[ -z "$(header_value x-rack-defaults)" ] && ok "the Live marker never reaches the client" || bad "the avatar leaks x-rack-defaults"
[ -n "$(header_value x-version)" ] && ok "the avatar carries x-version" || bad "the avatar has no x-version"
[ -n "$(header_value x-rev)" ] && ok "the avatar carries x-rev" || bad "the avatar has no x-rev"
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

# --- avatar fallback ----------------------------------------------------------------------------------------
# Rails serves an SVG when no stored avatar exists: the default-bot SVG for a bot, initials otherwise. David
# (user 1) is a seed user with no avatar, so his signed token names the initials SVG.
initials_avatar=$(avatar_token 1) || fail "could not mint user 1's Rails signed_id"
req GET "/users/$initials_avatar/avatar" -H "Cookie: $cookie"
status_is "GET /users/:token/avatar with no stored avatar" 200
content_type_is "the initials avatar is image/svg+xml" image/svg+xml
has_text "the initials SVG is the 512 viewBox" 'viewBox="0 0 512 512" class="avatar" aria-hidden="true"'
has_text "the initials SVG has the porthole clipPath" 'id="porthole"'
has_text "the initials SVG's rect is user 1's palette colour (crc32(\"1\") % 18 == 11)" 'fill="#BF7C2A"'
has_text "the initials SVG has the centred white text" 'fill="#FFFFFF"'
has_text "the initials are David Heinemeier's DH" '      DH'
lacks_text "two initials do not stretch the text" 'textLength="85%"'
has_text "the initials SVG has the display font stack" 'font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif"'
for attr in 'dy="0.35em"' 'font-size="230"' 'font-weight="800"' 'letter-spacing="-5"'; do
	if grep -Fq -- "$attr" "$body"; then ok "the initials SVG carries $attr"; else bad "the initials SVG lacks $attr"; fi
done
initials_etag=$(sed -n 's/^[Ee][Tt]ag: *//p' "$hdr" | tr -d '\r' | head -n 1)
case "$initials_etag" in
'W/"avatar-'*) ok "the initials SVG carries a weak avatar ETag: $initials_etag" ;;
*) bad "the initials SVG ETag shape is [$initials_etag]" ;;
esac
initials_cache=$(sed -n 's/^[Cc]ache-[Cc]ontrol: *//p' "$hdr" | tr -d '\r' | head -n 1)
case "$initials_cache" in
*public*max-age=1800*stale-while-revalidate=604800*) ok "the initials SVG is publicly cacheable for 30 minutes with a one-week stale window" ;;
*) bad "the initials SVG Cache-Control is [$initials_cache]" ;;
esac
: >"$body"
req GET "/users/$initials_avatar/avatar" -H "Cookie: $cookie" -H "If-None-Match: $initials_etag"
status_is "the initials SVG with its own ETag" 304
if [ -s "$body" ]; then bad "the initials SVG 304 carries a body"; else ok "the initials SVG 304 has no body"; fi

# a bot with no avatar is the default-bot SVG, byte for byte (app/assets/images/default-bot-avatar.svg).
sqlite3 "$db" "UPDATE users SET role = 2 WHERE id = 1"
# use_layer :front caches the public initials response above, as Thruster does; the app's avatar URLs carry
# ?v=<updated_at>, so a changed user is a new URL. A fresh ?v= asks for the bot avatar past that cache.
req GET "/users/$initials_avatar/avatar?v=bot" -H "Cookie: $cookie"
status_is "GET a bot's avatar with no stored avatar" 200
content_type_is "the bot avatar is image/svg+xml" image/svg+xml
if cmp -s "$body" "$root/public/default-bot-avatar.svg"; then ok "the bot avatar's bytes are public/default-bot-avatar.svg"; else bad "the bot avatar's bytes differ from public/default-bot-avatar.svg"; fi
if grep -Fq 'enable-background="new 0 0 18 18"' "$body"; then ok "the bot avatar is the default-bot SVG"; else bad "the bot avatar is not the default-bot SVG"; fi
sqlite3 "$db" "UPDATE users SET role = 1 WHERE id = 1"

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
if [ "$(ids "SELECT COUNT(*) FROM memberships WHERE room_id = 1 AND user_id = (SELECT id FROM users WHERE email_address = '$email') AND unread_at IS NULL")" = "0" ]; then ok "a room visit leaves unread_at alone (PresenceChannel clears it)"; else bad "a room visit cleared unread_at"; fi
same_ids "room_show" "$(ids "SELECT id FROM (SELECT id, created_at FROM messages WHERE room_id=1 ORDER BY created_at DESC LIMIT 40) ORDER BY created_at")"
has_text "the page is a full document (doctype)" "<!DOCTYPE html>"
has_text "the page is a full document (closing tag)" "</html>"
has_text "the messages container id" "id=\"messages_rooms_open_1\""
has_text "message 90 carries id=message_client-90 (dom_id uses client_message_id)" "id=\"message_client-90\""
has_text "the layout links the fingerprinted stylesheet" "href=\"/assets/_reset-$reset_digest.css\""
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
has_text "the 200 for a different ETag is the full page" "id=\"messages_rooms_open_1\""
room_cache=$(sed -n 's/^[Cc]ache-[Cc]ontrol: *//p' "$hdr" | tr -d '\r' | head -n 1)
# use_layer :rack_defaults: Rack::ETag's policy for a page with an ETag, and Vary: Accept because curl's bare
# `Accept: */*` is not a browser-like list, so Rails derives the format from it.
case "$room_cache" in
"max-age=0, private, must-revalidate") ok "the room page is Cache-Control: max-age=0, private, must-revalidate" ;;
*) bad "the room page Cache-Control is [$room_cache]" ;;
esac
room_vary=$(sed -n 's/^[Vv]ary: *//p' "$hdr" | tr -d '\r' | head -n 1)
case "$room_vary" in
*Accept*) ok "the room page varies on Accept" ;;
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

# --- 404s as Rails writes them, and the Active Storage blob redirect ---
# verify_join_code is `head :not_found`: an empty text/html answer, with the controller stack's headers.
req GET /join/not-a-code
status_is "GET /join/not-a-code" 404
ctype=$(sed -n 's/^[Cc]ontent-[Tt]ype: *//p' "$hdr" | tr -d '\r' | head -n 1)
if [ "$ctype" = "text/html" ]; then ok "the join 404 is text/html"; else bad "the join 404 content type is [$ctype], wanted [text/html]"; fi
# User.find raises RecordNotFound: PublicExceptions writes public/404.html with its own spelling and none of the stack's headers.
req GET /users/999999999 -H "Cookie: $cookie"
status_is "GET /users/999999999" 404
ctype=$(sed -n 's/^[Cc]ontent-[Tt]ype: *//p' "$hdr" | tr -d '\r' | head -n 1)
if [ "$ctype" = "text/html; charset=UTF-8" ]; then ok "the public 404 page is text/html; charset=UTF-8"; else bad "the public 404 content type is [$ctype], wanted [text/html; charset=UTF-8]"; fi
if grep -qi '^x-frame-options:' "$hdr"; then bad "the public 404 page carries the stack's security headers"; else ok "the public 404 page carries none of the stack's headers"; fi
# A blob redirect with a signature that does not verify is `head :not_found`.
req GET /rails/active_storage/blobs/redirect/not-a-signed-id/photo.jpg
status_is "GET a blob redirect with a bad signature" 404
# The sidebar loads the new-ping form as a Turbo frame: turbo-rails' frame layout, so no stylesheet preload Link.
req GET /rooms/directs/new -H "Cookie: $cookie" -H "Turbo-Frame: direct_rooms_control"
status_is "GET /rooms/directs/new as a frame" 200
if grep -qi '^link:' "$hdr"; then bad "the new-ping frame carries a preload Link"; else ok "the new-ping frame carries no preload Link"; fi
# A failed login renders the form (401) in the layout: the preload Link and the session cookie come with it.
req POST /session -d "email_address=$email" -d "password=wrong" -H "Accept: text/vnd.turbo-stream.html, text/html"
status_is "POST /session with a wrong password" 401
if grep -qi '^link:' "$hdr"; then ok "the failed login carries the preload Link"; else bad "the failed login lacks the preload Link"; fi
if grep -qi '^set-cookie: *_campfire_session=' "$hdr"; then ok "the failed login writes the session cookie"; else bad "the failed login lacks the session cookie"; fi

# --- the flash for a room david is not in (RoomsController#set_room), carried in the _campfire_session value ---
req GET /rooms/3 -H "Cookie: $cookie; _campfire_session=tok"
redirects "a room david is not in goes to /" /
flash_cookie=$(sed -n 's/^[Ss]et-[Cc]ookie: *\(_campfire_session=[^;]*\).*/\1/p' "$hdr" | tr -d '\r' | head -n 1)
if [ "$flash_cookie" = "_campfire_session=tok.room_not_found" ]; then ok "the redirect carries the alert in _campfire_session"; else bad "the _campfire_session cookie is [$flash_cookie], wanted [_campfire_session=tok.room_not_found]"; fi
req GET / -H "Cookie: $cookie; $flash_cookie"
redirects "/ with the alert goes on to a room" /rooms/1
flash_cookie=$(sed -n 's/^[Ss]et-[Cc]ookie: *\(_campfire_session=[^;]*\).*/\1/p' "$hdr" | tr -d '\r' | head -n 1)
if [ "$flash_cookie" = "_campfire_session=tok.room_not_found" ]; then ok "/ keeps the alert in the cookie"; else bad "after / the cookie is [$flash_cookie], wanted the alert kept"; fi
req GET /rooms/1 -H "Cookie: $cookie; $flash_cookie"
status_is "the room page after the alert" 200
has_text "the room page shows the alert" "Room not found or inaccessible"
has_text "the alert is a negative flash" "--color-negative"
flash_cookie=$(sed -n 's/^[Ss]et-[Cc]ookie: *\(_campfire_session=[^;]*\).*/\1/p' "$hdr" | tr -d '\r' | head -n 1)
if [ "$flash_cookie" = "_campfire_session=tok" ]; then ok "the room page writes the cookie back without the alert"; else bad "after the room page the cookie is [$flash_cookie], wanted [_campfire_session=tok]"; fi
req GET /rooms/1 -H "Cookie: $cookie; $flash_cookie"
lacks_text "the alert is shown once" "Room not found or inaccessible"


# --- Turbo-Frame requests answer turbo-rails' frame layout (Rooms::InvolvementsController#show) ---
req GET /rooms/1/involvement -H "Cookie: $cookie"
has_text "the involvement button without a frame header has the application layout" "<!DOCTYPE html>"
req GET /rooms/1/involvement -H "Cookie: $cookie" -H "Turbo-Frame: involvement_rooms_open_1"
status_is "GET /rooms/1/involvement as a Turbo-Frame request" 200
has_text "the frame answer holds the frame" "<turbo-frame id=\"involvement_rooms_open_1\""
lacks_text "the frame answer has no application layout" "<!DOCTYPE html>"
lacks_text "the frame answer has no stylesheet" "stylesheet"
if sed -n 's/^[Ll]ink:.*/link/p' "$hdr" | grep -q link; then bad "the frame answer carries a preload Link"; else ok "the frame answer has no preload Link"; fi

# --- the stock app icon (Accounts::LogosController#send_stock_icon; needs public/logos/app-icon{,-192}.png) ---
if [ "$(ids "SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = 'Account' AND name = 'logo'")" = "0" ]; then
	req GET "/account/logo?v=1"
	status_is "GET /account/logo with no logo uploaded" 200
	content_type_is "the stock icon is a PNG" "image/png"
	logo_disposition=$(sed -n 's/^[Cc]ontent-[Dd]isposition: *//p' "$hdr" | tr -d '\r' | head -n 1)
	if [ "$logo_disposition" = "inline; filename=\"app-icon.png\"; filename*=UTF-8''app-icon.png" ]; then ok "the stock icon names app-icon.png inline"; else bad "the stock icon Content-Disposition is [$logo_disposition]"; fi
	if sed -n 's/^[Cc]ontent-[Tt]ransfer-[Ee]ncoding: *binary.*/binary/p' "$hdr" | grep -q binary; then ok "the stock icon is Content-Transfer-Encoding: binary"; else bad "the stock icon lacks Content-Transfer-Encoding: binary"; fi
	if sed -n 's/^[Ee][Tt]ag: .*/etag/p' "$hdr" | grep -q etag; then ok "the stock icon has an ETag"; else bad "the stock icon has no ETag"; fi
fi

# --- the earlier-messages page -----------------------------------------------------------------------------
sqlite3 "$db" "UPDATE memberships SET unread_at = '2026-01-01 00:00:00' WHERE room_id = 1 AND user_id = (SELECT id FROM users WHERE email_address = '$email')"
req GET "/rooms/1/messages?before=60" -H "Cookie: $cookie"
status_is "GET /rooms/1/messages?before=60" 200
if [ "$(ids "SELECT COUNT(*) FROM memberships WHERE room_id = 1 AND user_id = (SELECT id FROM users WHERE email_address = '$email') AND unread_at IS NULL")" = "0" ]; then ok "the earlier-messages page leaves unread_at alone"; else bad "the earlier-messages page cleared unread_at"; fi
same_ids "messages_page" "$(ids "SELECT id FROM (SELECT id, created_at FROM messages WHERE room_id=1 AND created_at < (SELECT created_at FROM messages WHERE id=60) ORDER BY created_at DESC LIMIT 40) ORDER BY created_at")"
lacks_text "the fragment has no layout" "<html"
req GET "/rooms/1/messages?before=1" -H "Cookie: $cookie"
status_is "no earlier messages" 204
[ -z "$(header_value content-type)" ] && ok "the 204 carries no Content-Type (Rails' head :no_content)" || bad "the 204 carries content-type [$(header_value content-type)]"
for sec in x-frame-options x-content-type-options x-xss-protection x-permitted-cross-domain-policies referrer-policy; do
	[ -n "$(header_value "$sec")" ] && ok "the 204 carries $sec" || bad "the 204 has no $sec"
done

# --- QrCodeController#show (allow_unauthenticated_access): rqrcode's SVG, public for a year ---------------------
req GET "/qr_code/aHR0cDovL2NhbXBmaXJlLnRlc3Q="
status_is "GET /qr_code/:id without a cookie" 200
content_type_is "the QR code is an SVG" "image/svg+xml"
case "$(head -c 200 "$body")" in
'<?xml version="1.0" standalone="yes"?><svg version="1.1"'*) ok "the QR code is rqrcode's SVG" ;;
*) bad "the QR code body does not start like rqrcode's SVG" ;;
esac
case "$(header_value cache-control)" in
*max-age=31556952*public* | *public*max-age=31556952*) ok "the QR code is public for a year" ;;
*) bad "the QR code Cache-Control is [$(header_value cache-control)]" ;;
esac
req GET "/qr_code/a"
status_is "a malformed QR id" 500

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

# --- the web app manifest: Rails' Rack::ETag applies to JSON, not only HTML/Turbo Stream ---------------------
req GET /webmanifest.json
status_is "GET /webmanifest.json" 200
manifest_etag=$(sed -n 's/^[Ee][Tt]ag: *//p' "$hdr" | tr -d '\r' | head -n 1)
if [ -n "$manifest_etag" ]; then ok "the webmanifest carries an ETag: $manifest_etag"; else bad "the webmanifest has no ETag"; fi
manifest_cache=$(sed -n 's/^[Cc]ache-[Cc]ontrol: *//p' "$hdr" | tr -d '\r' | head -n 1)
case "$manifest_cache" in
*max-age=0*private*must-revalidate*) ok "the webmanifest is private and revalidates" ;;
*) bad "the webmanifest Cache-Control is [$manifest_cache]" ;;
esac

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

# --- the front layer: what Rack::Deflater and Thruster did to a Rails response ----------------------------------
# An asset, for a client that takes gzip: Propshaft's Cache-Control, gzip, Vary and X-Cache, and no Accept-Ranges.
asset_header() { grep -i "^$1:" "$hdr" | head -1 | sed 's/^[^:]*: *//' | tr -d '\r'; }
req GET "/assets/campfire-$css_digest.css" -H "Accept-Encoding: gzip"
status_is "the asset for a client that accepts gzip" 200
[ "$(asset_header cache-control)" = "max-age=2592000, public" ] && ok "the asset's Cache-Control is max-age=2592000, public" || bad "the asset's Cache-Control is [$(asset_header cache-control)]"
[ "$(asset_header content-encoding)" = "gzip" ] && ok "the asset is gzipped" || bad "the asset's Content-Encoding is [$(asset_header content-encoding)]"
[ "$(asset_header vary)" = "accept-encoding" ] && ok "the asset varies on accept-encoding" || bad "the asset's Vary is [$(asset_header vary)]"
[ "$(asset_header x-cache)" = "miss" ] && ok "the first asset request is an X-Cache miss" || bad "the asset's X-Cache is [$(asset_header x-cache)]"
[ -z "$(asset_header accept-ranges)" ] && ok "the asset has no Accept-Ranges" || bad "the asset sends Accept-Ranges"
req GET "/assets/campfire-$css_digest.css" -H "Accept-Encoding: gzip"
[ "$(asset_header x-cache)" = "hit" ] && ok "the second asset request is an X-Cache hit" || bad "the second asset X-Cache is [$(asset_header x-cache)]"
if has gzip && gzip -dc <"$body" 2>/dev/null | cmp -s - "$root/public/campfire.css"; then ok "the cached gzip body decodes to the file's bytes"; else bad "the cached gzip body does not decode to public/campfire.css"; fi
req GET "/assets/campfire-$css_digest.css"
[ -z "$(asset_header content-encoding)" ] && ok "a client without Accept-Encoding gets the identity body" || bad "an identity request got Content-Encoding [$(asset_header content-encoding)]"
[ "$(asset_header vary)" = "accept-encoding" ] && ok "the identity response still varies on accept-encoding" || bad "the identity response's Vary is [$(asset_header vary)]"
req GET "/assets/campfire-$css_digest.css" -H "Range: bytes=0-9"
[ "$(asset_header x-cache)" = "bypass" ] && ok "a range request bypasses the cache" || bad "the range request's X-Cache is [$(asset_header x-cache)]"
# Propshaft's own names, pinned from the Rails reference: lexxy.css imports lexxy-content.css and lexxy-editor.css
# (which both import lexxy-variables.css); the served CSS names the digested files, and the digest covers them.
req GET /assets/lexxy-2876c58e.css
status_is "lexxy.css under Propshaft's digest" 200
has_text "lexxy.css imports the digested lexxy-content.css" '@import url("/assets/lexxy-content-0ff2f961.css");'
has_text "lexxy.css imports the digested lexxy-editor.css" '@import url("/assets/lexxy-editor-2d5c7ebe.css");'
req GET /assets/lexxy-content-0ff2f961.css
has_text "lexxy-content.css imports the digested lexxy-variables.css" '@import url("/assets/lexxy-variables-3fef4323.css");'
# A page: Vary gains accept-encoding after the app's own tokens, and X-Cache is a bypass or miss, never absent.
req GET /session/new -H "Accept-Encoding: gzip"
[ "$(asset_header content-encoding)" = "gzip" ] && ok "a page is gzipped for a client that accepts it" || bad "the page's Content-Encoding is [$(asset_header content-encoding)]"
case "$(asset_header vary)" in *accept-encoding*) ok "a page varies on accept-encoding";; *) bad "the page's Vary is [$(asset_header vary)]";; esac
[ -n "$(asset_header x-cache)" ] && ok "a page carries X-Cache" || bad "a page has no X-Cache"

# The static error pages are ActionDispatch::Static files: Rails' Cache-Control and none of the application headers.
req GET /404.html -H "Accept-Encoding: gzip"
status_is "GET /404.html" 200
[ "$(asset_header cache-control)" = "max-age=2592000, public" ] && ok "the error page has max-age=2592000, public" || bad "the error page's Cache-Control is [$(asset_header cache-control)]"
[ -z "$(asset_header set-cookie)" ] && [ -z "$(asset_header x-frame-options)" ] && [ -z "$(asset_header link)" ] && ok "the error page has no application headers" || bad "the error page carries application headers"

# --- posting a message --------------------------------------------------------------------------------------
before_messages=$(ids "SELECT COUNT(*) FROM messages")
before_rich=$(ids "SELECT COUNT(*) FROM action_text_rich_texts")
before_index=$(ids "SELECT COUNT(*) FROM message_search_index")

posted="e2e stream message"
client_id="e2e-client-message-1"
req POST /rooms/1/messages -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "message%5Bbody%5D=$posted" --data-urlencode "message%5Bclient_message_id%5D=$client_id"
status_is "POST /rooms/1/messages" 200
content_type_is "the stream is a Turbo Stream" "text/vnd.turbo-stream.html"
[ "$(asset_header content-type)" = "text/vnd.turbo-stream.html; charset=utf-8" ] && ok "the stream has Rails' charset" || bad "the stream's Content-Type is [$(asset_header content-type)]"
case "$(asset_header etag)" in W/*) ok "the POST answer carries a Rack::ETag";; *) bad "the POST answer has no ETag: [$(asset_header etag)]";; esac
[ "$(asset_header cache-control)" = "max-age=0, private, must-revalidate" ] && ok "the POST answer is max-age=0, private, must-revalidate" || bad "the POST answer's Cache-Control is [$(asset_header cache-control)]"
has_text "the stream appends to the room" "<turbo-stream action=\"append\" target=\"messages_rooms_open_1\">"
has_text "the stream carries a template" "<template>"
has_text "the stream carries the submitted text" "$posted"
new_message_id=$(ids "SELECT MAX(id) FROM messages")
if [ "$(ids "SELECT COUNT(*) FROM messages")" = "$((before_messages + 1))" ]; then ok "the message row was inserted"; else bad "the message count did not grow by one"; fi
if [ "$(ids "SELECT COUNT(*) FROM action_text_rich_texts WHERE record_type='Message' AND record_id=$new_message_id AND name='body'")" = "1" ]; then ok "the rich text row was inserted"; else bad "no rich text row for message $new_message_id"; fi
if [ "$(ids "SELECT COUNT(*) FROM message_search_index WHERE rowid=$new_message_id")" = "1" ]; then ok "the FTS row was inserted"; else bad "no FTS row for message $new_message_id"; fi
if [ "$(ids "SELECT client_message_id FROM messages WHERE id=$new_message_id")" = "$client_id" ]; then ok "the bracketed client_message_id reached the row"; else bad "the client_message_id row is [$(ids "SELECT client_message_id FROM messages WHERE id=$new_message_id")]"; fi

req GET /rooms/1 -H "Cookie: $cookie"
status_is "GET /rooms/1 after the post" 200
has_text "the room page shows the new message (dom_id uses client_message_id)" "id=\"message_$client_id\""
new_etag=$(sed -n 's/^[Ee][Tt]ag: *//p' "$hdr" | tr -d '\r' | head -n 1)
if [ -n "$new_etag" ] && [ "$new_etag" != "$room_etag" ]; then ok "the ETag changes when a message arrives: $new_etag"; else bad "the ETag after the post is [$new_etag], wanted a change from [$room_etag]"; fi

req POST /rooms/1/messages -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "body=flat wire name"
status_is "a flat body does not satisfy message[body]" 422
req POST /rooms/1/messages --data-urlencode "message%5Bbody%5D=no cookie"
redirects "POST /rooms/1/messages without a cookie" /session/new
req POST /rooms/3/messages -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "message%5Bbody%5D=not a member"
# MessagesController#create runs set_room inside the action and rescues RecordNotFound with `render action: :room_not_found`.
status_is "POST to a room david is not in renders room_not_found" 200
has_text "the room_not_found answer shakes the composer" "shake"
after_messages=$(ids "SELECT COUNT(*) FROM messages")
after_rich=$(ids "SELECT COUNT(*) FROM action_text_rich_texts")
after_index=$(ids "SELECT COUNT(*) FROM message_search_index")
if [ "$after_messages" = "$((before_messages + 1))" ] && [ "$after_rich" = "$((before_rich + 1))" ] && [ "$after_index" = "$((before_index + 1))" ]; then
	ok "the refused posts inserted nothing"
else
	bad "the refused posts changed the database"
fi

# --- editing, deleting and boosting a message (messages_controller.rb, messages/boosts_controller.rb) ---------------
# Rails forms send update and delete as a POST with a hidden _method field; :method_override routes them. Message 3 is
# david's (an administrator) in room 1; jason is a member who did not write it. Unrun until the owner saves the tree.
req POST /session -H "Sec-Fetch-Site: same-origin" --data-urlencode "email_address=jason@37signals.com" --data-urlencode "password=$password"
jcookie=$(login_cookie)
[ -n "$jcookie" ] && ok "jason signs in for the edit checks" || bad "jason got no session_token"
frame="Turbo-Frame: edit_message_client-3"

req GET /rooms/1/messages/3/edit -H "Cookie: $cookie" -H "$frame"
status_is "GET /rooms/1/messages/3/edit" 200
content_type_is "the edit form is HTML" text/html
has_text "the edit form is the message's edit frame" "<turbo-frame id=\"edit_message_client-3\">"
has_text "the edit form is the editing body" "message__body-content--editing"
has_text "the edit form patches the message" "<input type=\"hidden\" name=\"_method\" value=\"patch\">"
has_text "the edit form posts to the message" "action=\"/rooms/1/messages/3\""
has_text "the editor holds the body" "<lexxy-editor id=\"message_body\""
has_text "the editor is named message[body]" "name=\"message[body]\""
has_text "the editor carries the mention prompt" "<lexxy-prompt trigger=\"@\" name=\"mention\" src=\"/autocompletable/users?room_id=1\""
has_text "the editor holds the stored text" "Plain chatter number 3"
has_text "the form has a Save changes button" "Save changes"
has_text "the form has a delete form" "id=\"delete_form_message_client-3\""
has_text "the editor has a close link" "message__edit-close-btn"
has_text "a frame request still gets the app layout (MessagesController declares a layout)" "name=\"viewport\""
if grep -qi '^link:' "$hdr"; then ok "the edit frame carries the preload Link, as Rails' full page does"; else bad "the edit frame lacks the preload Link"; fi
req GET /rooms/1/messages/3/edit -H "Cookie: $cookie"
status_is "GET /rooms/1/messages/3/edit outside a frame" 200
has_text "outside a frame the form is wrapped in the app layout" "name=\"viewport\""
req GET /rooms/1/messages/3/edit -H "Cookie: $jcookie" -H "$frame"
status_is "a member cannot edit another's message (ensure_can_administer)" 403
req GET /rooms/1/messages/4/edit -H "Cookie: $jcookie" -H "$frame"
status_is "a member can edit their own message" 200
req GET /rooms/1/messages/999/edit -H "Cookie: $cookie" -H "$frame"
status_is "the edit form of a message that does not exist" 404
req GET /rooms/3/messages/111/edit -H "Cookie: $cookie" -H "$frame"
status_is "the edit form of a room david is not in" 404
req GET /rooms/1/messages/3/edit
redirects "the edit form without a cookie" /session/new

before_touch=$(ids "SELECT updated_at FROM messages WHERE id = 3")
req POST /rooms/1/messages/3 -H "Sec-Fetch-Site: same-origin" -H "Cookie: $jcookie" --data-urlencode "_method=patch" --data-urlencode "message%5Bbody%5D=<p>jason tries</p>"
status_is "a member cannot update another's message" 403
if [ "$(ids "SELECT COUNT(*) FROM action_text_rich_texts WHERE record_id = 3 AND body LIKE '%jason tries%'")" = "0" ]; then ok "the refused update changed nothing"; else bad "the refused update wrote the body"; fi
req POST /rooms/1/messages/3 -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "_method=patch" --data-urlencode "message%5Bbody%5D=<p>Edited by e2e marmalade</p>"
status_is "POST _method=patch updates the message" 302
redirects "the update goes back to the message" /rooms/1/messages/3
if [ "$(ids "SELECT COUNT(*) FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = 3 AND name = 'body' AND body = '<p>Edited by e2e marmalade</p>'")" = "1" ]; then ok "the rich text row holds the new body"; else bad "the rich text row of message 3 is [$(ids "SELECT body FROM action_text_rich_texts WHERE record_id = 3")]"; fi
if [ "$(ids "SELECT COUNT(*) FROM message_search_index WHERE rowid = 3 AND body LIKE '%Edited by e2e marmalade%'")" = "1" ]; then ok "the FTS row follows the edit"; else bad "the FTS row of message 3 is [$(ids "SELECT body FROM message_search_index WHERE rowid = 3")]"; fi
if [ "$(ids "SELECT COUNT(*) FROM message_search_index WHERE message_search_index MATCH 'marmalade' AND rowid = 3")" = "1" ]; then ok "search finds the edited text"; else bad "an FTS MATCH for the edited text misses message 3"; fi
after_touch=$(ids "SELECT updated_at FROM messages WHERE id = 3")
if [ "$after_touch" != "$before_touch" ]; then ok "the edit touched the message"; else bad "the message's updated_at is still $before_touch"; fi
req GET /rooms/1/messages/3 -H "Cookie: $cookie" -H "$frame"
status_is "the update's redirect lands on the message" 200
has_text "the message shows the edit" "Edited by e2e marmalade"
has_text "the message is back in its frame" "<turbo-frame id=\"edit_message_client-3\">"

# Boosts: only a member of the message's room may reach them.
bframe="Turbo-Frame: new_boost_message_client-3"
req GET /messages/3/boosts/new -H "Cookie: $cookie" -H "$bframe"
status_is "GET /messages/3/boosts/new" 200
content_type_is "the boost form is HTML" text/html
has_text "the boost form is the new_boost frame" "<turbo-frame id=\"new_boost_message_client-3\">"
has_text "the boost form posts to the message's boosts" "action=\"/messages/3/boosts\""
has_text "the boost form targets the boosting frame" "data-turbo-frame=\"boosting_message_client-3\""
has_text "the boost input is input--boost" "input input--boost txt-small"
has_text "the boost input is limited to 16 characters" "maxlength=\"16\""
has_text "the boost input is named boost[content]" "name=\"boost[content]\""
has_text "the boost form cancels to the boosts" "href=\"/messages/3/boosts\""
req GET /messages/111/boosts/new -H "Cookie: $cookie" -H "$bframe"
status_is "the boost form of a message in a room david is not in" 404
req GET /messages/3/boosts/new
redirects "the boost form without a cookie" /session/new

req POST /messages/3/boosts -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "boost%5Bcontent%5D=Great!"
status_is "POST /messages/3/boosts" 302
redirects "a boost goes to the message's boosts" /messages/3/boosts
if [ "$(ids "SELECT COUNT(*) FROM boosts WHERE message_id = 3 AND booster_id = 1 AND content = 'Great!'")" = "1" ]; then ok "the boost row was inserted for david"; else bad "no boost row for message 3 by david"; fi
req POST /messages/3/boosts -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "boost%5Bcontent%5D=👍"
redirects "a quick boost goes to the message's boosts" /messages/3/boosts
req POST /messages/111/boosts -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "boost%5Bcontent%5D=nope"
status_is "a boost on a message in a room david is not in" 404
req POST /messages/3/boosts -H "Sec-Fetch-Site: same-origin" --data-urlencode "boost%5Bcontent%5D=no cookie"
redirects "a boost without a cookie" /session/new
req GET /messages/3/boosts -H "Cookie: $cookie" -H "Turbo-Frame: boosting_message_client-3"
status_is "GET /messages/3/boosts" 200
has_text "the boosts are the boosting frame" "<turbo-frame id=\"boosting_message_client-3\">"
has_text "the boosts hold a boost-item" "boost boost-item"
has_text "the boosts hold the typed boost" "Great!"
david_boost=$(ids "SELECT id FROM boosts WHERE message_id = 3 AND content = 'Great!'")
has_text "the boost has its dom id" "id=\"boost_$david_boost\""
has_text "the boost has its delete button" "action=\"/messages/3/boosts/$david_boost\""

req POST /messages/3/boosts/$david_boost -H "Sec-Fetch-Site: same-origin" -H "Cookie: $jcookie" --data-urlencode "_method=delete"
status_is "another user cannot delete david's boost" 404
req POST /messages/3/boosts/$david_boost -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "_method=delete"
status_is "POST _method=delete removes the booster's own boost" 204
if [ ! -s "$body" ]; then ok "the boost delete has no body (204 No Content)"; else bad "the boost delete has a body"; fi
if [ "$(ids "SELECT COUNT(*) FROM boosts WHERE id = $david_boost")" = "0" ]; then ok "the boost row is gone"; else bad "the boost row is still there"; fi

# Deleting a message takes its boosts, body and FTS row with it.
req POST /rooms/1/messages -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "message%5Bbody%5D=to be deleted" --data-urlencode "message%5Bclient_message_id%5D=e2e-del"
del_id=$(ids "SELECT id FROM messages WHERE client_message_id = 'e2e-del'")
req POST /messages/$del_id/boosts -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "boost%5Bcontent%5D=bye"
req POST /rooms/1/messages/$del_id -H "Sec-Fetch-Site: same-origin" -H "Cookie: $jcookie" --data-urlencode "_method=delete"
status_is "a member cannot delete another's message" 403
if [ "$(ids "SELECT COUNT(*) FROM messages WHERE id = $del_id")" = "1" ]; then ok "the refused delete kept the message"; else bad "the refused delete removed the message"; fi
req POST /rooms/1/messages/$del_id -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "_method=delete"
status_is "POST _method=delete removes the message" 200
content_type_is "the delete answers a Turbo Stream" "text/vnd.turbo-stream.html"
has_text "the stream removes the message" "<turbo-stream action=\"remove\" target=\"message_e2e-del\">"
if [ "$(ids "SELECT (SELECT COUNT(*) FROM messages WHERE id = $del_id) + (SELECT COUNT(*) FROM boosts WHERE message_id = $del_id) + (SELECT COUNT(*) FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = $del_id) + (SELECT COUNT(*) FROM message_search_index WHERE rowid = $del_id)")" = "0" ]; then ok "the message, its boosts, body and FTS row are gone"; else bad "rows of message $del_id survive its delete"; fi
req POST /rooms/1/messages/$del_id -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "_method=delete"
status_is "deleting a message twice" 404

# --- creating and deleting a room, the involvement button, a search -------------------------------------------
# Rooms::OpensController#create: the creator's membership and every active user's, a redirect to the room.
# (Unrun until the owner saves the tree.)
req POST /rooms/opens -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "room%5Bname%5D=E2E open room"
new_room=$(ids "SELECT id FROM rooms WHERE name = 'E2E open room' AND type = 'Rooms::Open'")
[ -n "$new_room" ] || bad "POST /rooms/opens created no open room"
redirects "POST /rooms/opens" "/rooms/$new_room"
if [ "$(ids "SELECT COUNT(*) FROM memberships WHERE room_id = $new_room AND involvement = 'mentions'")" = "$(ids "SELECT COUNT(*) FROM users WHERE status = 0")" ]; then ok "a new open room grants every active user a mentions membership"; else bad "the new open room's memberships are not one per active user"; fi
if [ "$(ids "SELECT COUNT(*) FROM rooms WHERE id = $new_room AND creator_id = (SELECT id FROM users WHERE email_address = '$email')")" = "1" ]; then ok "the new room's creator is the signed-in user"; else bad "the new room has another creator"; fi
req GET "/rooms/$new_room" -H "Cookie: $cookie"
status_is "GET the new room" 200
# RoomsController#destroy: only an administrator or the creator.
req POST "/rooms/$new_room" -H "Sec-Fetch-Site: same-origin" -H "Cookie: $jcookie" --data-urlencode "_method=delete"
status_is "a member who is not the creator cannot delete a room" 403
req POST "/rooms/$new_room/messages" -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "message%5Bbody%5D=going away" --data-urlencode "message%5Bclient_message_id%5D=e2e-room-msg"
req POST "/rooms/$new_room" -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "_method=delete"
redirects "POST _method=delete on a room" "/"
if [ "$(ids "SELECT (SELECT COUNT(*) FROM rooms WHERE id = $new_room) + (SELECT COUNT(*) FROM memberships WHERE room_id = $new_room) + (SELECT COUNT(*) FROM messages WHERE room_id = $new_room)")" = "0" ]; then ok "deleting a room removes its memberships and messages"; else bad "the deleted room left rows behind"; fi
# MessagesController#create's rescue: a room the user is no longer in renders messages/room_not_found (200).
req POST "/rooms/$new_room/messages" -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "message%5Bbody%5D=anyone here?" --data-urlencode "message%5Bclient_message_id%5D=e2e-room-gone"
status_is "posting to a deleted room" 200
has_text "the deleted room's answer is the composer frame with the shake" "composer__input input input--actor shake"
has_text "the deleted room's answer says so" "This room was deleted."
# Rooms::InvolvementsController#update: PUT through _method, then back to the button.
req POST "/rooms/1/involvement?involvement=everything" -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "_method=put"
redirects "PUT /rooms/1/involvement" "/rooms/1/involvement"
if [ "$(ids "SELECT involvement FROM memberships WHERE room_id = 1 AND user_id = (SELECT id FROM users WHERE email_address = '$email')")" = "everything" ]; then ok "the involvement is saved"; else bad "the involvement was not saved"; fi
req POST "/rooms/1/involvement?involvement=mentions" -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "_method=put"
# SearchesController#create: the query is recorded and the answer redirects to its results.
req POST /searches -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "q=e2e launch!"
redirects "POST /searches" "/searches?q=e2e+launch+"
if [ "$(ids "SELECT COUNT(*) FROM searches WHERE query = 'e2e launch ' AND user_id = (SELECT id FROM users WHERE email_address = '$email')")" = "1" ]; then ok "the search is recorded with punctuation as spaces"; else bad "the search was not recorded"; fi

# --- Action Cable -----------------------------------------------------------------------------------------
# The endpoint and its six channels from campfire.axum.rb. test/cable_check.mjs speaks actioncable-v1-json over
# a real WebSocket against this same seeded, running service, with the session this script signed in with;
# test/cable_broadcast_check.mjs then checks the frames the routes and channels broadcast.
mine="room_id = 1 AND user_id = (SELECT id FROM users WHERE email_address = '$email')"
sqlite3 "$db" "UPDATE memberships SET unread_at = '2026-01-01 00:00:00', connected_at = NULL, connections = 0 WHERE $mine"
if has node; then
	if CABLE_COOKIE="$cookie" node "$here/cable_check.mjs" "$base"; then
		ok "the Action Cable endpoint confirms the six app channels and Turbo's two streams, and rejects the rest"
	else
		bad "the Action Cable endpoint check failed"
	fi
	# The check's PresenceChannel subscription for room 1 is Membership.connect: unread_at cleared, one connection.
	if [ "$(ids "SELECT COUNT(*) FROM memberships WHERE $mine AND unread_at IS NULL AND connected_at IS NOT NULL AND connections = 1")" = "1" ]; then ok "subscribing to PresenceChannel clears unread_at and counts one connection"; else bad "subscribing to PresenceChannel left unread_at or connections unchanged"; fi
	# What the routes and channels broadcast, as the frames Rails sends: david and jason (jcookie, from the edit checks above)
	# subscribe to room 1; david posts, boosts, edits, types and deletes. Unrun until the owner saves the tree.
	if CABLE_COOKIE="$cookie" CABLE_COOKIE_JASON="$jcookie" node "$here/cable_broadcast_check.mjs" "$base"; then
		ok "the message, boost, edit, delete, typing, unread and presence-read broadcasts reach the room as the frames Rails sends"
	else
		bad "the Action Cable broadcast check failed"
	fi
else
	bad "the Action Cable check needs node, which is not on PATH"
fi

# --- the notices of the update forms (UNRUN: written for the owner's run on the saved tree) ---------------------------
# AccountsController#update and Users::ProfilesController#update redirect with `notice:`; the notice travels in the
# _campfire_session cookie's value as a suffix on the session token (.notice_saved, .notice_avatar), is shown once by the
# page the redirect lands on, and the page writes the bare token back.
session_cookie_value() {
	sed -n 's/^[Ss]et-[Cc]ookie: *\(_campfire_session=[^;]*\).*/\1/p' "$hdr" | tr -d '\r' | head -n 1
}

req POST /account.1 -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie; _campfire_session=tok" --data-urlencode "_method=patch" --data-urlencode "account%5Bname%5D=Renamed HQ"
status_is "PATCH /account.1 (the name form) by an administrator" 302
redirects "the account update goes back to its settings" /account/edit
[ "$(session_cookie_value)" = "_campfire_session=tok.notice_saved" ] && ok "the account update carries the notice in _campfire_session" || bad "the _campfire_session cookie is [$(session_cookie_value)], wanted [_campfire_session=tok.notice_saved]"
[ "$(ids "SELECT name FROM accounts")" = "Renamed HQ" ] && ok "the account name was saved" || bad "the account name is [$(ids "SELECT name FROM accounts")]"
req GET /account/edit -H "Cookie: $cookie; _campfire_session=tok.notice_saved"
status_is "GET /account/edit after the update" 200
has_text "the account page shows the flash" 'class="flash"'
has_text "the notice is the check mark" "✓"
has_text "the form holds the new name" 'value="Renamed HQ"'
[ "$(session_cookie_value)" = "_campfire_session=tok" ] && ok "the account page writes the cookie back without the notice" || bad "after the account page the cookie is [$(session_cookie_value)], wanted [_campfire_session=tok]"
req GET /account/edit -H "Cookie: $cookie; _campfire_session=tok"
lacks_text "the account notice is shown once" 'class="flash"'
req POST /account.1 -H "Sec-Fetch-Site: same-origin" -H "Cookie: $jcookie" --data-urlencode "_method=patch" --data-urlencode "account%5Bname%5D=Jason HQ"
status_is "PATCH /account.1 by a member (ensure_can_administer)" 403
[ "$(ids "SELECT name FROM accounts")" = "Renamed HQ" ] && ok "a member's account update changed nothing" || bad "a member renamed the account"

req POST /users/me/profile -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie; _campfire_session=tok" --data-urlencode "_method=patch" --data-urlencode "user%5Bbio%5D=Founder"
status_is "PATCH /users/me/profile (the bio) " 302
redirects "the profile update goes back to the profile" /users/me/profile
[ "$(session_cookie_value)" = "_campfire_session=tok.notice_saved" ] && ok "the profile update carries the check mark notice" || bad "the _campfire_session cookie is [$(session_cookie_value)], wanted [_campfire_session=tok.notice_saved]"
[ "$(ids "SELECT bio FROM users WHERE id = 1")" = "Founder" ] && ok "the bio was saved" || bad "the bio is [$(ids "SELECT bio FROM users WHERE id = 1")]"
[ "$(ids "SELECT name FROM users WHERE id = 1")" = "David Heinemeier" ] && ok "a key the form did not send (the name) was left alone" || bad "the name changed to [$(ids "SELECT name FROM users WHERE id = 1")]"
req GET /users/me/profile -H "Cookie: $cookie; _campfire_session=tok.notice_saved"
status_is "GET /users/me/profile after the update" 200
has_text "the profile shows the flash" 'class="flash"'
[ "$(session_cookie_value)" = "_campfire_session=tok" ] && ok "the profile writes the cookie back without the notice" || bad "after the profile the cookie is [$(session_cookie_value)], wanted [_campfire_session=tok]"
req GET /users/me/profile -H "Cookie: $cookie; _campfire_session=tok"
lacks_text "the profile notice is shown once" 'class="flash"'

# The avatar picker: a multipart body with `_method=patch` and `user[avatar]`. The file is stored under Active Storage's
# Disk layout, a blob and an attachment row are written, the user is touched and the notice is the avatar one.
printf 'not really a jpeg, but e2e bytes' >"$work/moon.jpg"
before_touch=$(ids "SELECT updated_at FROM users WHERE id = 1")
req POST /users/me/profile -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie; _campfire_session=tok" -F "_method=patch" -F "user[avatar]=@$work/moon.jpg;type=image/jpeg"
status_is "PATCH /users/me/profile with an avatar (multipart)" 302
redirects "the avatar update goes back to the profile" /users/me/profile
[ "$(session_cookie_value)" = "_campfire_session=tok.notice_avatar" ] && ok "the avatar update carries the 30 minutes notice" || bad "the _campfire_session cookie is [$(session_cookie_value)], wanted [_campfire_session=tok.notice_avatar]"
avatar_key=$(ids "SELECT b.key FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id = a.blob_id WHERE a.record_type = 'User' AND a.record_id = 1 AND a.name = 'avatar'")
[ "${#avatar_key}" = "28" ] && ok "the avatar blob has a 28 character key" || bad "the avatar blob key is [$avatar_key]"
[ "$(ids "SELECT b.filename || '|' || b.content_type || '|' || b.byte_size FROM active_storage_blobs b WHERE b.key = '$avatar_key'")" = "moon.jpg|image/jpeg|32" ] && ok "the avatar blob records the file" || bad "the avatar blob row is [$(ids "SELECT b.filename || '|' || b.content_type || '|' || b.byte_size FROM active_storage_blobs b WHERE b.key = '$avatar_key'")]"
if [ -f "$storage/$(printf %s "$avatar_key" | cut -c1-2)/$(printf %s "$avatar_key" | cut -c3-4)/$avatar_key" ] && cmp -s "$work/moon.jpg" "$storage/$(printf %s "$avatar_key" | cut -c1-2)/$(printf %s "$avatar_key" | cut -c3-4)/$avatar_key"; then ok "the avatar file is on disk at <root>/xx/yy/<key>"; else bad "no avatar file with the uploaded bytes at the Disk path of [$avatar_key]"; fi
[ "$(ids "SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = 'User' AND record_id = 1 AND name = 'avatar'")" = "1" ] && ok "one avatar attachment" || bad "avatar attachments: $(ids "SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = 'User' AND record_id = 1 AND name = 'avatar'")"
[ "$(ids "SELECT updated_at FROM users WHERE id = 1")" != "$before_touch" ] && ok "attaching the avatar touched the user" || bad "the user's updated_at did not move"
req GET /users/me/profile -H "Cookie: $cookie; _campfire_session=tok.notice_avatar"
has_text "the profile shows the avatar notice" "It may take up to 30 minutes to change everywhere."
has_text "the profile offers to delete the avatar" "avatar__delete-btn"
req POST /users/me/profile -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" -F "_method=patch" -F "user[avatar]=@$work/moon.jpg;type=image/jpeg"
[ "$(ids "SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = 'User' AND record_id = 1 AND name = 'avatar'")" = "1" ] && ok "a second avatar replaces the first (one attachment)" || bad "a second avatar left $(ids "SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = 'User' AND record_id = 1 AND name = 'avatar'") attachments"

# --- removing and replacing stored files: the avatar, the account logo (pinned as the code does them today) -----------------
# The ground truth for the Active Storage move to has_one_attached. DELETE /users/:token/avatar removes the SIGNED-IN person's
# avatar whatever the token says (People#destroy_avatar, Rails' `Current.user.avatar.destroy`); DELETE /account/logo and a
# replacing upload remove the account's. What goes today: the attachment row, the blob row, the variant records with their
# image attachments and variant blobs, and the user's/account's updated_at moves. What stays: every FILE under the storage root
# (the PurgeJob's file deletes are not reproduced), and a blob that an earlier avatar replacement detached (detach_avatar
# removes the attachment, never the blob; Rails purges it in a later job that this service does not run).
blob_path() { printf '%s/%s/%s/%s' "$storage" "$(printf %s "$1" | cut -c1-2)" "$(printf %s "$1" | cut -c3-4)" "$1"; }
# fake_variant SOURCE_KEY VARIANT_KEY DIGEST CONTENT_TYPE FILE: the rows and file Rails leaves once a variant was processed
# (a variant record, its blob, the `image` attachment between them), made by hand because the fixtures here are not images.
fake_variant() {
	sqlite3 "$db" "INSERT INTO active_storage_variant_records (blob_id, variation_digest) SELECT id, '$3' FROM active_storage_blobs WHERE key = '$1';
INSERT INTO active_storage_blobs (key, filename, content_type, metadata, service_name, byte_size, checksum, created_at) VALUES ('$2', 'variant', '$4', '{}', 'local', 20, NULL, '2025-01-01 08:00:00.000');
INSERT INTO active_storage_attachments (blob_id, record_type, record_id, name, created_at) SELECT (SELECT id FROM active_storage_blobs WHERE key = '$2'), 'ActiveStorage::VariantRecord', v.id, 'image', '2025-01-01 08:00:00.000' FROM active_storage_variant_records v WHERE v.blob_id = (SELECT id FROM active_storage_blobs WHERE key = '$1') AND v.variation_digest = '$3';"
	mkdir -p "$(dirname "$(blob_path "$2")")" && cp "$5" "$(blob_path "$2")"
}
# variant_rows SOURCE_KEY: "records|attachments|blobs" of that blob's variants (all three go when it is purged).
variant_rows() {
	ids "SELECT (SELECT COUNT(*) FROM active_storage_variant_records WHERE blob_id = (SELECT id FROM active_storage_blobs WHERE key = '$1')) || '|' || (SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = 'ActiveStorage::VariantRecord' AND record_id IN (SELECT id FROM active_storage_variant_records WHERE blob_id = (SELECT id FROM active_storage_blobs WHERE key = '$1'))) || '|' || (SELECT COUNT(*) FROM active_storage_blobs WHERE id IN (SELECT a.blob_id FROM active_storage_attachments a JOIN active_storage_variant_records v ON a.record_type = 'ActiveStorage::VariantRecord' AND a.record_id = v.id WHERE v.blob_id = (SELECT id FROM active_storage_blobs WHERE key = '$1')))"
}

# David's avatar: the second upload above is attached (the first upload's blob was detached by the replacement). Give it a
# processed variant, so the route serves it, then delete it.
david_key=$(ids "SELECT b.key FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id = a.blob_id WHERE a.record_type = 'User' AND a.record_id = 1 AND a.name = 'avatar'")
[ "${#david_key}" = "28" ] && [ "$david_key" != "$avatar_key" ] && ok "David's attached avatar is the replacement's blob, not the first upload's" || bad "David's avatar blob key is [$david_key] (the first upload's was [$avatar_key])"
fake_variant "$david_key" e2edavidavatarvariant000001 6gwfjNKv9eUy9jNUtEZvQFLU0hQ= image/webp "$storage/ja/so/jasonavatarvariant"
[ "$(variant_rows "$david_key")" = "1|1|1" ] && ok "David's avatar has a variant record, its image attachment and its blob" || bad "David's avatar variant rows are [$(variant_rows "$david_key")]"
req GET "/users/$initials_avatar/avatar?v=with-avatar" -H "Cookie: $cookie"
status_is "GET David's avatar once it has a variant" 200
content_type_is "David's variant is image/webp" image/webp
if cmp -s "$body" "$storage/ja/so/jasonavatarvariant"; then ok "the avatar route serves the variant's file"; else bad "the avatar route did not serve the variant's bytes"; fi
avatar_touch_before=$(ids "SELECT updated_at FROM users WHERE id = 1")
req POST "/users/$initials_avatar/avatar" -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "_method=delete"
redirects "DELETE /users/:token/avatar goes back to the profile (Rails redirect_to user_profile_url)" /users/me/profile
[ "$(ids "SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = 'User' AND record_id = 1 AND name = 'avatar'")" = "0" ] && ok "the avatar attachment row is gone" || bad "the avatar attachment is still there"
[ "$(ids "SELECT COUNT(*) FROM active_storage_blobs WHERE key = '$david_key'")" = "0" ] && ok "the avatar's blob row is gone (purged)" || bad "the avatar's blob row is still there"
[ "$(variant_rows "$david_key")" = "0|0|0" ] && [ "$(ids "SELECT COUNT(*) FROM active_storage_blobs WHERE key = 'e2edavidavatarvariant000001'")" = "0" ] && ok "the avatar's variant record, image attachment and variant blob are gone" || bad "avatar variant rows left: [$(variant_rows "$david_key")]"
[ -f "$(blob_path "$david_key")" ] && [ -f "$(blob_path e2edavidavatarvariant000001)" ] && ok "the avatar's files stay on disk (no file is purged)" || bad "a purged avatar's file was removed from disk"
[ "$(ids "SELECT COUNT(*) FROM active_storage_blobs WHERE key = '$avatar_key'")" = "1" ] && ok "the blob the replacement detached stays (no purge job runs)" || bad "the replaced avatar's first blob row is gone"
[ "$(ids "SELECT updated_at FROM users WHERE id = 1")" != "$avatar_touch_before" ] && ok "deleting the avatar touched the user" || bad "the user's updated_at did not move on avatar delete"
req GET "/users/$initials_avatar/avatar?v=no-avatar" -H "Cookie: $cookie"
status_is "GET David's avatar after the delete" 200
content_type_is "the avatar is the initials SVG again" image/svg+xml
has_text "the initials are David Heinemeier's DH" '      DH'
req POST "/users/$initials_avatar/avatar" -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "_method=delete"
redirects "deleting an avatar that is not there is a no-op redirect to the profile" /users/me/profile

# Jason's seeded avatar has a real variant from the seed (blobs 1 and 2, attachments 1 and 2, variant record 1); the token in
# the path is David's here, to show the signed-in person's avatar goes, not the path's.
jason_touch_before=$(ids "SELECT updated_at FROM users WHERE id = 2")
[ "$(variant_rows jasonavatarsource)" = "1|1|1" ] && ok "Jason's seeded avatar has its variant rows" || bad "Jason's variant rows are [$(variant_rows jasonavatarsource)]"
req POST "/users/$initials_avatar/avatar" -H "Sec-Fetch-Site: same-origin" -H "Cookie: $jcookie" --data-urlencode "_method=delete"
redirects "Jason's avatar delete goes back to the profile" /users/me/profile
[ "$(ids "SELECT (SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = 'User' AND name = 'avatar') + (SELECT COUNT(*) FROM active_storage_blobs WHERE key IN ('jasonavatarsource', 'jasonavatarvariant')) + (SELECT COUNT(*) FROM active_storage_variant_records WHERE id = 1) + (SELECT COUNT(*) FROM active_storage_attachments WHERE id IN (1, 2))")" = "0" ] && ok "Jason's avatar, its variant record and both blobs are gone (no other user has an avatar)" || bad "rows of Jason's avatar remain"
[ -f "$storage/ja/so/jasonavatarvariant" ] && ok "Jason's variant file stays on disk" || bad "Jason's variant file was removed"
[ "$(ids "SELECT updated_at FROM users WHERE id = 2")" != "$jason_touch_before" ] && ok "deleting Jason's avatar touched him" || bad "Jason's updated_at did not move on avatar delete"
req GET "/users/$avatar/avatar?v=no-avatar" -H "Cookie: $cookie"
content_type_is "Jason's avatar is the initials SVG after the delete" image/svg+xml
has_text "the initials are Jason Fried's JF" '      JF'

# The account logo. A member's upload is refused; the administrator's is stored; the logo route serves a logo's processed
# :large PNG variant and the stock icon when the logo has none (this e2e's logo bytes are not an image, so the variant is
# made by hand: fake_variant). A replacing upload purges the old logo, its variants and their blobs; DELETE does the same.
printf 'e2e logo one' >"$work/logo1.png"
printf 'e2e logo number two' >"$work/logo2.png"
printf 'e2e logo variant, not the stock icon' >"$work/logo.variant.png"
logo_digest="ksXvpLsa7BuCVyHOwmQOKedbIbM="
logos() { ids "SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = 'Account' AND name = 'logo'"; }
[ "$(logos)" = "0" ] && ok "the account starts without a logo" || bad "the account already has $(logos) logo attachments"
req POST /account.1 -H "Sec-Fetch-Site: same-origin" -H "Cookie: $jcookie" -F "_method=patch" -F "account[logo]=@$work/logo1.png;type=image/png"
status_is "a member cannot upload the account logo (ensure_can_administer)" 403
[ "$(logos)" = "0" ] && ok "the refused logo upload attached nothing" || bad "a member's logo upload attached a logo"
logo_touch_before=$(ids "SELECT updated_at FROM accounts")
req POST /account.1 -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" -F "_method=patch" -F "account[logo]=@$work/logo1.png;type=image/png"
status_is "PATCH /account.1 with a logo (multipart)" 302
redirects "the logo upload goes back to the account settings" /account/edit
[ "$(logos)" = "1" ] && ok "one logo attachment" || bad "logo attachments: $(logos)"
logo_key1=$(ids "SELECT b.key FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id = a.blob_id WHERE a.record_type = 'Account' AND a.name = 'logo'")
[ "$(ids "SELECT filename || '|' || content_type || '|' || byte_size FROM active_storage_blobs WHERE key = '$logo_key1'")" = "logo1.png|image/png|12" ] && ok "the logo blob records the file" || bad "the logo blob row is [$(ids "SELECT filename || '|' || content_type || '|' || byte_size FROM active_storage_blobs WHERE key = '$logo_key1'")]"
cmp -s "$work/logo1.png" "$(blob_path "$logo_key1")" && ok "the logo file is on disk at <root>/xx/yy/<key>" || bad "no logo file with the uploaded bytes at the Disk path of [$logo_key1]"
[ "$(ids "SELECT updated_at FROM accounts")" != "$logo_touch_before" ] && ok "attaching the logo touched the account (the logo's ?v=)" || bad "the account's updated_at did not move on the logo upload"
fake_variant "$logo_key1" e2elogovariantone0000000001 "$logo_digest" image/png "$work/logo.variant.png"
req GET "/account/logo?v=logo-one"
status_is "GET /account/logo with a processed logo" 200
content_type_is "the logo is image/png" image/png
if cmp -s "$body" "$work/logo.variant.png"; then ok "the logo route serves the logo's variant file"; else bad "the logo route did not serve the variant's bytes"; fi
if cmp -s "$body" "$root/public/logos/app-icon.png"; then bad "the logo route still serves the stock icon"; else ok "the logo route does not serve the stock icon"; fi

req POST /account.1 -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" -F "_method=patch" -F "account[logo]=@$work/logo2.png;type=image/png"
redirects "a second logo upload goes back to the account settings" /account/edit
[ "$(logos)" = "1" ] && ok "a second logo replaces the first (one attachment)" || bad "a second logo left $(logos) attachments"
logo_key2=$(ids "SELECT b.key FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id = a.blob_id WHERE a.record_type = 'Account' AND a.name = 'logo'")
[ -n "$logo_key2" ] && [ "$logo_key2" != "$logo_key1" ] && ok "the attached logo is the new blob" || bad "the attached logo key is [$logo_key2] (the first was [$logo_key1])"
[ "$(ids "SELECT filename || '|' || byte_size FROM active_storage_blobs WHERE key = '$logo_key2'")" = "logo2.png|19" ] && ok "the new logo blob records the file" || bad "the new logo blob row is [$(ids "SELECT filename || '|' || byte_size FROM active_storage_blobs WHERE key = '$logo_key2'")]"
[ "$(ids "SELECT COUNT(*) FROM active_storage_blobs WHERE key = '$logo_key1'")" = "0" ] && ok "the replaced logo's blob row is gone" || bad "the replaced logo's blob row is still there"
[ "$(variant_rows "$logo_key1")" = "0|0|0" ] && [ "$(ids "SELECT COUNT(*) FROM active_storage_blobs WHERE key = 'e2elogovariantone0000000001'")" = "0" ] && ok "the replaced logo's variant record, image attachment and variant blob are gone" || bad "replaced logo variant rows left: [$(variant_rows "$logo_key1")]"
[ -f "$(blob_path "$logo_key1")" ] && [ -f "$(blob_path e2elogovariantone0000000001)" ] && ok "the replaced logo's files stay on disk" || bad "a replaced logo's file was removed from disk"
req GET "/account/logo?v=logo-two"
status_is "GET /account/logo with a logo that has no variant yet" 200
if cmp -s "$body" "$root/public/logos/app-icon.png"; then ok "the new logo (not processed) answers the stock icon"; else bad "the unprocessed logo did not answer the stock icon"; fi

fake_variant "$logo_key2" e2elogovarianttwo0000000001 "$logo_digest" image/png "$work/logo.variant.png"
logo_touch_before=$(ids "SELECT updated_at FROM accounts")
req POST /account/logo -H "Sec-Fetch-Site: same-origin" -H "Cookie: $jcookie" --data-urlencode "_method=delete"
status_is "a member cannot delete the account logo (ensure_can_administer)" 403
[ "$(logos)" = "1" ] && [ "$(variant_rows "$logo_key2")" = "1|1|1" ] && ok "the refused logo delete kept the logo and its variant" || bad "a member's logo delete changed rows: logos $(logos), variants [$(variant_rows "$logo_key2")]"
req POST /account/logo -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "_method=delete"
redirects "DELETE /account/logo goes back to the account settings" /account/edit
[ "$(logos)" = "0" ] && ok "the logo attachment row is gone" || bad "the logo attachment is still there"
[ "$(ids "SELECT COUNT(*) FROM active_storage_blobs WHERE key = '$logo_key2'")" = "0" ] && ok "the logo's blob row is gone (purged)" || bad "the logo's blob row is still there"
[ "$(variant_rows "$logo_key2")" = "0|0|0" ] && [ "$(ids "SELECT COUNT(*) FROM active_storage_blobs WHERE key = 'e2elogovarianttwo0000000001'")" = "0" ] && ok "the logo's variant record, image attachment and variant blob are gone" || bad "logo variant rows left: [$(variant_rows "$logo_key2")]"
[ -f "$(blob_path "$logo_key2")" ] && [ -f "$(blob_path e2elogovarianttwo0000000001)" ] && ok "the deleted logo's files stay on disk" || bad "a deleted logo's file was removed from disk"
[ "$(ids "SELECT updated_at FROM accounts")" != "$logo_touch_before" ] && ok "deleting the logo touched the account (the logo's ?v=)" || bad "the account's updated_at did not move on logo delete"
req GET "/account/logo?v=logo-gone"
status_is "GET /account/logo after the delete" 200
if cmp -s "$body" "$root/public/logos/app-icon.png"; then ok "after the delete the logo route serves the stock icon again"; else bad "the logo route did not fall back to the stock icon"; fi
req POST /account/logo -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "_method=delete"
redirects "deleting a logo that is not there is a no-op redirect to the account settings" /account/edit

# --- the composer's file post (MessagesController#create with `message[attachment]`, no body) ---------------------------
printf 'attachment e2e bytes' >"$work/photo.jpg"
req POST /rooms/1/messages -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" -H "Accept: text/vnd.turbo-stream.html" -F "message[attachment]=@$work/photo.jpg;type=image/jpeg" -F "message[client_message_id]=e2e-att"
status_is "POST /rooms/1/messages with an attachment and no body" 200
content_type_is "the attachment post answers a Turbo Stream" "text/vnd.turbo-stream.html"
has_text "the stream draws the attachment" "message__attachment"
att_message=$(ids "SELECT id FROM messages WHERE client_message_id = 'e2e-att' AND room_id = 1 AND creator_id = 1")
[ -n "$att_message" ] && ok "the message row exists" || bad "no message row for the attachment post"
att_key=$(ids "SELECT b.key FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id = a.blob_id WHERE a.record_type = 'Message' AND a.record_id = $att_message AND a.name = 'attachment'")
[ "${#att_key}" = "28" ] && ok "the message's attachment blob has a 28 character key" || bad "the attachment key is [$att_key]"
[ "$(ids "SELECT filename || '|' || content_type || '|' || byte_size FROM active_storage_blobs WHERE key = '$att_key'")" = "photo.jpg|image/jpeg|20" ] && ok "the attachment blob records the file" || bad "the attachment blob row is [$(ids "SELECT filename || '|' || content_type || '|' || byte_size FROM active_storage_blobs WHERE key = '$att_key'")]"
cmp -s "$work/photo.jpg" "$storage/$(printf %s "$att_key" | cut -c1-2)/$(printf %s "$att_key" | cut -c3-4)/$att_key" && ok "the attachment file is on disk" || bad "no attachment file at the Disk path of [$att_key]"
[ "$(ids "SELECT COUNT(*) FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = $att_message")" = "0" ] && ok "a message with no body has no rich text row" || bad "the attachment message has a rich text row"
[ "$(ids "SELECT body FROM message_search_index WHERE rowid = $att_message")" = "photo.jpg" ] && ok "the search index holds the filename (Message#plain_text_body)" || bad "the search index row is [$(ids "SELECT body FROM message_search_index WHERE rowid = $att_message")]"
req GET /rooms/1 -H "Cookie: $cookie"
has_text "the room page draws the attachment message" "message__attachment"

# --- deleting a message that has an attachment (Message#destroy purges the attachment's blobs with their variants) ---------
# The composer's file post above made message $att_message with photo.jpg. Give the blob a processed variant by hand, then
# delete the message as its creator: the message, its attachment row, the blob row, the variant record, its image attachment
# and its blob go; the two files stay on disk (no file is purged).
att_variant_key=e2emessagevariant0000000001
fake_variant "$att_key" "$att_variant_key" e2emessagevariantdigest= image/jpeg "$work/photo.jpg"
[ "$(variant_rows "$att_key")" = "1|1|1" ] && ok "the message attachment has a variant record, its image attachment and its blob" || bad "the message attachment's variant rows are [$(variant_rows "$att_key")]"
req POST "/rooms/1/messages/$att_message" -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "_method=delete"
status_is "POST _method=delete removes the message that has an attachment" 200
has_text "the stream removes the attachment message" "<turbo-stream action=\"remove\" target=\"message_e2e-att\">"
[ "$(ids "SELECT COUNT(*) FROM messages WHERE id = $att_message")" = "0" ] && ok "the attachment message row is gone" || bad "the attachment message row is still there"
[ "$(ids "SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = 'Message' AND record_id = $att_message")" = "0" ] && ok "the message's attachment row is gone" || bad "the message's attachment row is still there"
[ "$(ids "SELECT COUNT(*) FROM active_storage_blobs WHERE key = '$att_key'")" = "0" ] && ok "the attachment's blob row is gone (purged)" || bad "the attachment's blob row is still there"
[ "$(variant_rows "$att_key")" = "0|0|0" ] && [ "$(ids "SELECT COUNT(*) FROM active_storage_blobs WHERE key = '$att_variant_key'")" = "0" ] && ok "the attachment's variant record, image attachment and variant blob are gone" || bad "attachment variant rows left: [$(variant_rows "$att_key")]"
[ -f "$(blob_path "$att_key")" ] && [ -f "$(blob_path "$att_variant_key")" ] && ok "the attachment's files stay on disk" || bad "a purged attachment's file was removed from disk"
[ "$(ids "SELECT COUNT(*) FROM message_search_index WHERE rowid = $att_message")" = "0" ] && ok "the attachment message's FTS row is gone" || bad "the attachment message's FTS row is still there"

# --- the join form (UsersController#create; multipart, an empty avatar input) --------------------------------------------
req POST /join/wrong-code -H "Sec-Fetch-Site: same-origin" -F "user[name]=Nora New" -F "user[email_address]=nora@example.com" -F "user[password]=secret123456" -F "user[avatar]="
status_is "POST /join with a wrong code" 404
[ "$(ids "SELECT COUNT(*) FROM users WHERE email_address = 'nora@example.com'")" = "0" ] && ok "a wrong join code creates nobody" || bad "a wrong join code created a user"
req POST /join/abcd-1234 -H "Sec-Fetch-Site: same-origin" -F "user[name]=Nora New" -F "user[email_address]=nora@example.com" -F "user[password]=secret123456" -F "user[avatar]="
status_is "POST /join/abcd-1234 (no avatar chosen)" 302
redirects "the join goes to /" /
nora_cookie=$(login_cookie)
[ -n "$nora_cookie" ] && ok "the join sets a session_token cookie" || bad "the join set no session_token cookie"
nora_id=$(ids "SELECT id FROM users WHERE email_address = 'nora@example.com' AND name = 'Nora New' AND role = 0 AND status = 0")
[ -n "$nora_id" ] && ok "the new user exists (member, active)" || bad "no user row for the join"
[ "$(ids "SELECT COUNT(*) FROM users WHERE id = $nora_id AND password_digest LIKE '\$2%'")" = "1" ] && ok "the password is a BCrypt digest" || bad "the password digest is not BCrypt"
[ "$(ids "SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = 'User' AND record_id = $nora_id")" = "0" ] && ok "an empty avatar input attaches nothing" || bad "the join attached an avatar"
[ "$(ids "SELECT room_id FROM memberships WHERE user_id = $nora_id ORDER BY room_id")" = "$(ids "SELECT id FROM rooms WHERE type = 'Rooms::Open' ORDER BY id")" ] && ok "the new user is in every open room" || bad "the new user's rooms are [$(ids "SELECT room_id FROM memberships WHERE user_id = $nora_id ORDER BY room_id")]"
[ "$(ids "SELECT COUNT(*) FROM sessions WHERE user_id = $nora_id")" = "1" ] && ok "the join started a session" || bad "no session row for the new user"
req GET / -H "Cookie: $nora_cookie"
case "$status" in 302) ok "the new user's / redirects to a room" ;; *) bad "GET / for the new user answered $status" ;; esac
req POST /join/abcd-1234 -H "Sec-Fetch-Site: same-origin" -F "user[name]=Ava Avatar" -F "user[email_address]=ava@example.com" -F "user[password]=secret123456" -F "user[avatar]=@$work/moon.jpg;type=image/jpeg"
status_is "POST /join with an avatar" 302
[ "$(ids "SELECT COUNT(*) FROM active_storage_attachments a JOIN users u ON u.id = a.record_id WHERE a.record_type = 'User' AND a.name = 'avatar' AND u.email_address = 'ava@example.com'")" = "1" ] && ok "a chosen avatar is attached to the new user" || bad "the join with an avatar attached nothing"

# --- GET /rooms/:id/refresh for a room the user is not in (RoomScoped find_by!) ---------------------------------------
req GET "/rooms/3/refresh?since=0" -H "Cookie: $cookie"
status_is "GET /rooms/3/refresh as a non-member" 404
ctype=$(sed -n 's/^[Cc]ontent-[Tt]ype: *//p' "$hdr" | tr -d '\r' | head -n 1)
[ "$ctype" = "text/html; charset=UTF-8" ] && ok "the refresh 404 is the public 404 page" || bad "the refresh 404 content type is [$ctype]"
has_text "the refresh 404 body is public/404.html" "We can’t find that (404)"

# --- the closed-room form (Rooms::ClosedsController#update) ------------------------------------------------------------
sqlite3 "$db" "INSERT INTO rooms (id, name, type, creator_id, created_at, updated_at) VALUES (6, 'Closed e2e', 'Rooms::Closed', 1, '2025-01-01 09:00:00.000', '2025-01-01 09:00:00.000');
INSERT INTO memberships (room_id, user_id, involvement, created_at, updated_at) VALUES (6, 1, 'mentions', '2025-01-01 09:00:00.000', '2025-01-01 09:00:00.000'), (6, 2, 'mentions', '2025-01-01 09:00:00.000', '2025-01-01 09:00:00.000');"
req POST /rooms/closeds/6 -H "Sec-Fetch-Site: same-origin" -H "Cookie: $jcookie" --data-urlencode "_method=patch" --data-urlencode "room%5Bname%5D=Jason edits"
status_is "PATCH /rooms/closeds/6 by a member who is neither administrator nor creator" 403
req POST /rooms/closeds/6 -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie; _campfire_session=tok" --data-urlencode "_method=patch" --data-urlencode "room%5Bname%5D=Renamed closed" --data-urlencode "user_ids%5B%5D=1" --data-urlencode "user_ids%5B%5D=3"
status_is "PATCH /rooms/closeds/6 by an administrator" 302
redirects "the closed-room update goes to the room" /rooms/6
[ "$(ids "SELECT name || '|' || type FROM rooms WHERE id = 6")" = "Renamed closed|Rooms::Closed" ] && ok "the room was renamed" || bad "the room row is [$(ids "SELECT name || '|' || type FROM rooms WHERE id = 6")]"
[ "$(ids "SELECT user_id FROM memberships WHERE room_id = 6 ORDER BY user_id")" = "1 3" ] && ok "memberships were revised: user 3 granted, user 2 revoked" || bad "the room's members are [$(ids "SELECT user_id FROM memberships WHERE room_id = 6 ORDER BY user_id")]"
req POST /rooms/closeds/6 -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie" --data-urlencode "_method=patch" --data-urlencode "room%5Bname%5D=Renamed closed"
[ "$(ids "SELECT COUNT(*) FROM memberships WHERE room_id = 6")" = "0" ] && ok "with no user_ids[] every member is revoked (params.fetch(:user_ids, []))" || bad "the room kept $(ids "SELECT COUNT(*) FROM memberships WHERE room_id = 6") members"
req POST /rooms/closeds/3 -H "Sec-Fetch-Site: same-origin" -H "Cookie: $cookie; _campfire_session=tok" --data-urlencode "_method=patch" --data-urlencode "room%5Bname%5D=Not mine"
redirects "PATCH /rooms/closeds/:id for a room david is not in goes to /" /
[ "$(session_cookie_value)" = "_campfire_session=tok.room_not_found" ] && ok "the missing room carries the alert" || bad "the _campfire_session cookie is [$(session_cookie_value)], wanted [_campfire_session=tok.room_not_found]"
[ "$(ids "SELECT name FROM rooms WHERE id = 3")" = "Skunkworks" ] && ok "a room david is not in kept its name" || bad "room 3 was renamed"

# --- a join with an e-mail address that is already taken (UsersController#create's RecordNotUnique rescue) -------------
req POST /join/abcd-1234 -H "Sec-Fetch-Site: same-origin" -F "user[name]=Another David" -F "user[email_address]=nora@example.com" -F "user[password]=secret123456" -F "user[avatar]="
status_is "POST /join with a taken e-mail" 302
redirects "a taken e-mail goes to the sign-in form prefilled" "/session/new?email_address=nora%40example.com"
if grep -qi '^set-cookie: *session_token=' "$hdr"; then bad "a taken-e-mail join set a session_token"; else ok "a taken-e-mail join sets no session_token"; fi
[ "$(ids "SELECT COUNT(*) FROM users WHERE email_address = 'nora@example.com'")" = "1" ] && ok "a taken-e-mail join creates nobody" || bad "a taken-e-mail join changed the users with nora@example.com"
req GET "/session/new?email_address=nora%40example.com"
status_is "GET /session/new with a prefilled address" 200
has_text "the sign-in form carries the address back" 'value="nora@example.com"'

# --- BlockBannedRequests: a banned address answers 429 to every non-GET/HEAD request ----------------------------------
sqlite3 "$db" "INSERT INTO bans (user_id, ip_address, created_at, updated_at) VALUES (1, '127.0.0.1', '2025-01-01 08:00:00.000', '2025-01-01 08:00:00.000');"
req POST /session -H "Sec-Fetch-Site: same-origin" --data-urlencode "email_address=$email" --data-urlencode "password=wrong"
status_is "POST /session from a banned address" 429
[ ! -s "$body" ] && ok "the banned-address 429 has an empty body" || bad "the banned-address 429 answered a body"
ctype=$(sed -n 's/^[Cc]ontent-[Tt]ype: *//p' "$hdr" | tr -d '\r' | head -n 1)
[ "$ctype" = "text/html" ] && ok "the banned-address 429 is text/html" || bad "the banned-address 429 content type is [$ctype]"
req GET /session/new
status_is "GET /session/new from a banned address" 200
sqlite3 "$db" "DELETE FROM bans WHERE ip_address = '127.0.0.1';"
sqlite3 "$db" "INSERT INTO bans (user_id, ip_address, created_at, updated_at) VALUES (1, '203.0.113.9', '2025-01-01 08:00:00.000', '2025-01-01 08:00:00.000');"
req POST /session -H "Sec-Fetch-Site: same-origin" -H "X-Forwarded-For: 203.0.113.9" --data-urlencode "email_address=nobody@example.com" --data-urlencode "password=wrong"
status_is "POST /session with the banned address in X-Forwarded-For" 429
req POST /session -H "Sec-Fetch-Site: same-origin" --data-urlencode "email_address=nobody@example.com" --data-urlencode "password=wrong"
[ "$status" != "429" ] && ok "the same POST without X-Forwarded-For is not banned" || bad "a POST without X-Forwarded-For was banned"
sqlite3 "$db" "DELETE FROM bans WHERE ip_address = '203.0.113.9';"

# --- the session transfer (Sessions::TransfersController#update; the page's form auto-submits a PUT) -------------------
transfer=$(transfer_token 1 14400)
req POST "/session/transfers/$transfer" -H "Sec-Fetch-Site: same-origin" --data-urlencode "_method=put"
status_is "PUT /session/transfers/:id (a valid link)" 302
redirects "the transfer signs in and goes to /" /
transfer_cookie=$(login_cookie)
[ -n "$transfer_cookie" ] && ok "the transfer sets a session_token cookie" || bad "the transfer set no session_token cookie"
req GET /rooms/1 -H "Cookie: $transfer_cookie"
status_is "GET /rooms/1 with the transfer's cookie" 200
expired=$(transfer_token 1 -60)
req POST "/session/transfers/$expired" -H "Sec-Fetch-Site: same-origin" --data-urlencode "_method=put"
status_is "PUT /session/transfers/:id (an expired link)" 400
[ ! -s "$body" ] && ok "the expired transfer answers an empty body" || bad "the expired transfer answered a body"
if grep -qi '^set-cookie: *session_token=' "$hdr"; then bad "an expired transfer set a session_token"; else ok "an expired transfer sets no session_token"; fi
case "$transfer" in
*0) tampered="${transfer%?}1" ;;
*) tampered="${transfer%?}0" ;;
esac
req POST "/session/transfers/$tampered" -H "Sec-Fetch-Site: same-origin" --data-urlencode "_method=put"
status_is "PUT /session/transfers/:id (a tampered link)" 400

# --- logout ------------------------------------------------------------------------------------------------

req DELETE /session -H "Cookie: $cookie"
redirects "the logout goes to / (Rails redirect_to root_url)" "/"
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
	echo "failed:$failures"
	# Again on stderr: a hook prints stderr after stdout, so the list is the last thing a truncated log keeps.
	echo "failed:$failures" >&2
	fail "$failed of $((passed + failed)) checks failed"
fi
echo "OK: $passed checks passed: login (302, cookie), the redirect without one, room_show ids and ETag, last_room, messages_page ids, the sidebar, search, posting a message, the avatar route, rooms david is not in, /up, the fingerprinted stylesheet, the Action Cable endpoint, the login rate limit, logout, and the avatar, account logo and message attachment removals and replacements (rows, variants, files, touches)"
