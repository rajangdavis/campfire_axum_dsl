D, K, J, JZ, LOU = "david@37signals.com", "kevin@37signals.com", "jason@37signals.com", "jz@37signals.com", "lou@37signals.com"
U = dict(david=127326141, jason=149087659, kevin=712064548, jz=773523953, lou=773523958, bender=394959859)
R = dict(pets=104393281, dj=186869642, hq=201306877, bk=340026324, talk=486777696, designers=654632876, dk=699448325,
         quiet=699448326, archive=699448327, broken=699448328, group=699448329)
SIDEBAR = ("/users/me/sidebar", "user_sidebar")  # loaded as the layout's lazy Turbo frame

SCENARIOS = [
    # Controls: routes the port already has, so the checker itself is known to pass on matching behaviour.
    dict(name="control/opens_create", seed="default", **{"as": D}, steps=[("POST", "/rooms/opens", {"room[name]": "Lobby"})], pages=[SIDEBAR]),
    dict(name="control/closeds_update", seed="default", **{"as": D},
         steps=[("PATCH", f"/rooms/closeds/{R['quiet']}", {"room[name]": "Quieter", "user_ids[]": [U["david"], U["jz"]]})], pages=[SIDEBAR]),

    # rooms/closeds#create
    dict(name="closeds/create", seed="default", **{"as": D},
         steps=[("POST", "/rooms/closeds", {"room[name]": "Secret", "user_ids[]": [U["david"], U["kevin"]]})], pages=[SIDEBAR, "/rooms/closeds/new"]),
    dict(name="closeds/create/none_checked", seed="default", **{"as": D},
         steps=[("POST", "/rooms/closeds", {"room[name]": "Nobody"})], pages=[SIDEBAR]),
    dict(name="closeds/create/member", seed="default", **{"as": K},
         steps=[("POST", "/rooms/closeds", {"room[name]": "Kevin's", "user_ids[]": [U["kevin"], U["jz"]]})], pages=[SIDEBAR]),
    dict(name="closeds/create/restricted_member", seed="restricted", **{"as": K},
         steps=[("POST", "/rooms/closeds", {"room[name]": "Nope", "user_ids[]": [U["kevin"]]})]),

    # rooms/directs#create
    dict(name="directs/create/new", seed="default", **{"as": D},
         steps=[("POST", "/rooms/directs", {"user_ids[]": [U["lou"]]})], pages=[SIDEBAR]),
    dict(name="directs/create/existing", seed="default", **{"as": D},
         steps=[("POST", "/rooms/directs", {"user_ids[]": [U["jason"]]})], pages=[SIDEBAR]),
    dict(name="directs/create/group", seed="default", **{"as": K},
         steps=[("POST", "/rooms/directs", {"user_ids[]": [U["jason"], U["jz"]]})], pages=[SIDEBAR]),
    dict(name="directs/create/self_only", seed="default", **{"as": LOU},
         steps=[("POST", "/rooms/directs", {})], pages=[SIDEBAR]),

    # rooms/directs#destroy
    dict(name="directs/destroy", seed="default", **{"as": D},
         steps=[("DELETE", f"/rooms/directs/{R['dk']}", {})], pages=[SIDEBAR, "/"]),
    dict(name="directs/destroy/not_a_direct", seed="default", **{"as": D},
         steps=[("DELETE", f"/rooms/directs/{R['hq']}", {})], pages=["/"]),
    dict(name="directs/destroy/not_member", seed="default", **{"as": LOU},
         steps=[("DELETE", f"/rooms/directs/{R['dj']}", {})], pages=["/"]),

    # rooms/opens#update
    dict(name="opens/update/rename", seed="default", **{"as": D},
         steps=[("PATCH", f"/rooms/opens/{R['hq']}", {"room[name]": "Headquarters"})], pages=[SIDEBAR, f"/rooms/{R['hq']}"]),
    dict(name="opens/update/closed_to_open", seed="default", **{"as": D},
         steps=[("PATCH", f"/rooms/opens/{R['designers']}", {"room[name]": "Designers"})], pages=[SIDEBAR]),
    dict(name="opens/update/not_admin", seed="default", **{"as": K},
         steps=[("PATCH", f"/rooms/opens/{R['hq']}", {"room[name]": "Kevin was here"})]),
    dict(name="opens/update/creator_member", seed="default", **{"as": K},
         steps=[("PATCH", f"/rooms/opens/{R['quiet']}", {"room[name]": "Loud Corner"})], pages=[SIDEBAR]),
    dict(name="opens/update/direct", seed="default", **{"as": D},
         steps=[("PATCH", f"/rooms/opens/{R['dj']}", {"room[name]": "Promoted"})], pages=["/"]),
]
