# Bot webhooks (MessagesController#deliver_webhooks_to_bots, Webhook#deliver): Bender's webhook is pointed at
# webhook_receiver.py (run it first: `python3 test/differential/webhook_receiver.py 4600 /tmp/hook.log`), a ping
# with Bender is opened, and a message is posted to it; the bot's reply (or the timeout notice) becomes a message.
# Each scenario's payloads land in the receiver's log, one per server: compare them with `webhooks_compare.py`.
import os
NOFILE = ("file", "")
D = "david@37signals.com"
BENDER = 394959859
HOOK = "http://172.17.0.1:4600"
ROOM = 699448330  # the ping POST /rooms/directs creates first


# The reply's client_message_id is Random.uuid; Rails' fragment cache keeps a broadcast-rendered message's copy link
# without the port (see botapi.py).
UUID = [(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", "<uuid4>")]
PAGE = [(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", "<uuid4>"), (r"http://(127\.0\.0\.1|HOST|example\.org)/rooms/", "http://HOST/rooms/")]


def hooked(name, path, body, settle=4):
    return dict(name=name, seed="default", **{"as": D}, settle=settle, masks=UUID, page_masks=PAGE, steps=[
        ("PATCH", f"/account/bots/{BENDER}", {"user[name]": "Bender Bot", "user[webhook_url]": f"{HOOK}{path}?case={name}", "user[avatar]": NOFILE}),
        ("POST", "/rooms/directs", {"user_ids[]": [BENDER]}),
        ("POST", f"/rooms/{ROOM}/messages", {"message[body]": body, "message[client_message_id]": "hook-1"}),
    ], pages=[f"/rooms/{ROOM}"])


SCENARIOS = [
    hooked("webhooks/reply_text", "/reply", "<div>Hello, <strong>Bender</strong> &amp; friends</div>"),
    hooked("webhooks/reply_html", "/html", "<div>Show me HTML</div>"),
    hooked("webhooks/no_reply", "/silent", "<div>Shh</div>"),
    hooked("webhooks/timeout", "/slow", "<div>Take your time</div>", settle=12),
]
