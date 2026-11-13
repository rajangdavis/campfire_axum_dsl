import os
D, K = "david@37signals.com", "kevin@37signals.com"
BENDER, DEPLOY, OLD, KEVIN = 394959859, 773523956, 773523957, 712064548
BOTS = "/account/bots"
AV = ("file", os.path.join(os.path.dirname(os.path.abspath(__file__)), "avatar.png"))
NOFILE = ("file", "")
TOKEN = [(r"^[A-Za-z0-9]{12}$", "<bot-token>")]
# The new key a create or a reset makes shows in the bots page's curl commands.
KEYS = [(r"(\d+)-[A-Za-z0-9]{12}/messages", r"\1-<bot-key>/messages")]

SCENARIOS = [
    dict(name="bots/create", seed="default", **{"as": D}, masks=TOKEN, page_masks=KEYS,
         steps=[("POST", "/account/bots", {"user[name]": "Weather Bot", "user[webhook_url]": "https://example.com/weather", "user[avatar]": NOFILE})], pages=[BOTS]),
    dict(name="bots/create/no_webhook", seed="default", **{"as": D}, masks=TOKEN, page_masks=KEYS,
         steps=[("POST", "/account/bots", {"user[name]": "Quiet Bot", "user[webhook_url]": "", "user[avatar]": NOFILE})], pages=[BOTS]),
    dict(name="bots/create/avatar", seed="default", **{"as": D}, settle=3, masks=TOKEN, page_masks=KEYS,
         steps=[("POST", "/account/bots", {"user[name]": "Pretty Bot", "user[webhook_url]": "", "user[avatar]": AV})], pages=[BOTS]),
    dict(name="bots/create/member", seed="default", **{"as": K},
         steps=[("POST", "/account/bots", {"user[name]": "Kevin Bot", "user[webhook_url]": "", "user[avatar]": NOFILE})]),
    dict(name="bots/update/rename", seed="default", **{"as": D},
         steps=[("PATCH", f"/account/bots/{BENDER}", {"user[name]": "Bender Rodriguez", "user[webhook_url]": "http://example.com/bender", "user[avatar]": NOFILE})], pages=[BOTS, f"/account/bots/{BENDER}/edit"]),
    dict(name="bots/update/webhook_cleared", seed="default", **{"as": D},
         steps=[("PATCH", f"/account/bots/{BENDER}", {"user[name]": "Bender Bot", "user[webhook_url]": "", "user[avatar]": NOFILE})], pages=[f"/account/bots/{BENDER}/edit"]),
    dict(name="bots/update/webhook_added", seed="default", **{"as": D},
         steps=[("PATCH", f"/account/bots/{DEPLOY}", {"user[name]": "Deploy Bot", "user[webhook_url]": "https://example.com/deploy", "user[avatar]": NOFILE})], pages=[f"/account/bots/{DEPLOY}/edit"]),
    dict(name="bots/update/inactive", seed="default", **{"as": D},
         steps=[("PATCH", f"/account/bots/{OLD}", {"user[name]": "Revived", "user[webhook_url]": "", "user[avatar]": NOFILE})]),
    dict(name="bots/update/not_a_bot", seed="default", **{"as": D},
         steps=[("PATCH", f"/account/bots/{KEVIN}", {"user[name]": "Kevin Bot", "user[webhook_url]": "", "user[avatar]": NOFILE})]),
    dict(name="bots/destroy", seed="default", **{"as": D}, steps=[("DELETE", f"/account/bots/{DEPLOY}", {})], pages=[BOTS]),
    dict(name="bots/destroy/member", seed="default", **{"as": K}, steps=[("DELETE", f"/account/bots/{DEPLOY}", {})]),
    dict(name="bots/destroy/inactive", seed="default", **{"as": D}, steps=[("DELETE", f"/account/bots/{OLD}", {})]),
    dict(name="bots/keys/update", seed="default", **{"as": D}, masks=TOKEN, page_masks=KEYS,
         steps=[("PUT", f"/account/bots/{BENDER}/key", {})], pages=[BOTS]),
    dict(name="bots/keys/update/member", seed="default", **{"as": K}, steps=[("PUT", f"/account/bots/{BENDER}/key", {})]),
    dict(name="bots/keys/update/inactive", seed="default", **{"as": D}, steps=[("PUT", f"/account/bots/{OLD}/key", {})]),
    # The pages beside them: administrators only, and a bot that is not one answers 404.
    dict(name="bots/pages/member", seed="default", **{"as": K}, steps=[], pages=[BOTS, "/account/bots/new", f"/account/bots/{BENDER}/edit"]),
    dict(name="bots/pages/unknown", seed="default", **{"as": D}, steps=[], pages=[f"/account/bots/{KEVIN}/edit", f"/account/bots/{OLD}/edit"]),
]
