import os
D, K = "david@37signals.com", "kevin@37signals.com"
BENDER_KEY, DEPLOY_KEY, OLD_KEY = "394959859-BenderBot123", "773523956-DeployBot456", "773523957-OldBot789abc"
TALK, PETS, HQ, BK = 486777696, 104393281, 201306877, 340026324
ROOM_PAGES = [f"/rooms/{TALK}", ("/users/me/sidebar", "user_sidebar")]
# Rails' message partial is fragment-cached; a message first rendered by its broadcast (no request: protocol and host,
# no port) keeps that copy link on the page. On a default port the two agree.
LINK = [(r"http://(127\.0\.0\.1|HOST)/rooms/(\d+)/@", r"http://HOST/rooms/\2/@"), (r"http://127\.0\.0\.1/rooms/", "http://HOST/rooms/")]
PUUID = [(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", "<uuid4>")]
IMG = ("file", os.path.join(os.path.dirname(os.path.abspath(__file__)), "avatar.png"))
UUID = [(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", "<uuid4>")]

SCENARIOS = [
    # The human composer's post, already in the port: the control for what a new message writes.
    dict(name="control/human_post", seed="default", **{"as": D}, settle=8, page_masks=LINK,
         steps=[("POST", f"/rooms/{TALK}/messages", {"message[body]": "<div>Hello from David</div>", "message[client_message_id]": "abc-123"}, {"Accept": "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"})], pages=ROOM_PAGES),

    # messages/by_bots#create
    dict(name="by_bots/create", seed="default", **{"as": D}, settle=8, masks=UUID, page_masks=LINK + PUUID,
         steps=[("POST", f"/rooms/{TALK}/{BENDER_KEY}/messages", b"Hello from Bender")], pages=ROOM_PAGES),
    dict(name="by_bots/create/blank", seed="default", steps=[("POST", f"/rooms/{TALK}/{BENDER_KEY}/messages", b"")]),
    dict(name="by_bots/create/not_member", seed="default", steps=[("POST", f"/rooms/{PETS}/{BENDER_KEY}/messages", b"Hi")]),
    dict(name="by_bots/create/bad_key", seed="default", steps=[("POST", f"/rooms/{TALK}/394959859-wrong/messages", b"Hi")]),
    dict(name="by_bots/create/inactive_bot", seed="default", steps=[("POST", f"/rooms/{TALK}/{OLD_KEY}/messages", b"Hi")]),
    dict(name="by_bots/create/direct", seed="default", **{"as": K}, settle=8, masks=UUID,
         steps=[("POST", f"/rooms/{BK}/{BENDER_KEY}/messages", b"Ping Kevin")], pages=[("/users/me/sidebar", "user_sidebar")]),

    # a multipart `attachment` (curl -F): the file is the message; a multipart body with no file part is a raw body
    dict(name="by_bots/create/attachment", seed="default", settle=8, masks=UUID,
         steps=[("POST", f"/rooms/{TALK}/{BENDER_KEY}/messages", ("multipart", {"attachment": IMG}))]),
    dict(name="by_bots/create/multipart_no_file", seed="default", settle=8, masks=UUID,
         steps=[("POST", f"/rooms/{TALK}/{BENDER_KEY}/messages", ("multipart", {"note": "hi"}))]),

    dict(name="by_bots/create/crlf", seed="default", settle=8, masks=UUID,
         steps=[("POST", f"/rooms/{TALK}/{BENDER_KEY}/messages", b"  line one\r\nline <b>two</b> & 3\r\n\r\n")]),

    # messages/by_bots#destroy: a message of the bot's own, someone else's (403 unless an administrator), a missing one
    dict(name="by_bots/destroy/own", seed="default", settle=8, masks=UUID,
         steps=[("POST", f"/rooms/{TALK}/{BENDER_KEY}/messages", b"Short-lived"),
                ("DELETE", f"/rooms/{TALK}/{BENDER_KEY}/messages/933434638", b"")]),
    dict(name="by_bots/destroy/others", seed="default", steps=[("DELETE", f"/rooms/654632876/{DEPLOY_KEY}/messages/309456473", b"")]),
    dict(name="by_bots/destroy/missing", seed="default", steps=[("DELETE", f"/rooms/{TALK}/{BENDER_KEY}/messages/1", b"")]),

    # messages/boosts/by_bots#destroy
    dict(name="boosts/by_bots/destroy/own", seed="default",
         steps=[("POST", f"/rooms/{TALK}/{BENDER_KEY}/messages/933434629/boosts", b"\xf0\x9f\x91\x8d"),
                ("DELETE", f"/rooms/{TALK}/{BENDER_KEY}/messages/933434629/boosts/329428245", b"")]),
    dict(name="boosts/by_bots/destroy/not_own", seed="default", steps=[("DELETE", f"/rooms/654632876/{DEPLOY_KEY}/messages/933434507/boosts/329428236", b"")]),
]
