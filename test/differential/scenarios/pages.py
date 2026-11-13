# Every page a person can open, on the default seed and on the ones the default-seed parity run does not cover: custom_styles (a logo and
# custom CSS), restricted (room creation for administrators only) and crowd (more than 500 people). Nothing is
# written; each viewer's pages are compared as DOM trees.
D, K = "david@37signals.com", "kevin@37signals.com"
HQ, DESIGNERS, DK, PETS, QUIET, MSG = 201306877, 654632876, 699448325, 104393281, 699448326, 933434569
JOIN = "CRMu-l8Ge-KB9B"
SIDEBAR = ("/users/me/sidebar", "user_sidebar")
SIGNED_IN = ["/", f"/rooms/{HQ}", f"/rooms/{DESIGNERS}", f"/rooms/{DK}", f"/rooms/{HQ}/@{MSG}", SIDEBAR, "/account/edit",
             "/account/bots", "/account/custom_styles/edit", "/users/me/profile", f"/users/127326141", "/searches",
             "/searches?q=coffee", "/rooms/opens/new", "/rooms/closeds/new", "/rooms/directs/new",
             f"/rooms/opens/{HQ}/edit", f"/rooms/closeds/{DESIGNERS}/edit", f"/rooms/directs/{DK}/edit",
             f"/rooms/closeds/{QUIET}/edit", "/users/me/push_subscriptions", "/users/me/sidebar", f"/rooms/{HQ}/involvement",
             f"/messages/{MSG}/boosts", "/webmanifest.json"]
SIGNED_OUT = ["/session/new", f"/join/{JOIN}", "/session/transfers/garbage", "/webmanifest.json", "/up", "/nope"]

SCENARIOS = []
for seed in ["default", "custom_styles", "restricted", "crowd"]:
    SCENARIOS += [
        dict(name=f"pages/{seed}/admin", seed=seed, **{"as": D}, steps=[], pages=SIGNED_IN),
        dict(name=f"pages/{seed}/member", seed=seed, **{"as": K}, steps=[], pages=SIGNED_IN),
        dict(name=f"pages/{seed}/signed_out", seed=seed, steps=[], pages=SIGNED_OUT),
    ]
