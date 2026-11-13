import os
LOGO = ("file", os.path.join(os.path.dirname(os.path.abspath(__file__)), "avatar.png"))
NOFILE = ("file", "")
ACCOUNT = "/account.873240054"
D, K, J = "david@37signals.com", "kevin@37signals.com", "jason@37signals.com"
U = dict(david=127326141, jason=149087659, kevin=712064548, jz=773523953, mallory=773523955, rita=773523954, bender=394959859, lou=773523958)
EDIT = "/account/edit"
CSS = "/account/custom_styles/edit"

SCENARIOS = [
    # accounts/custom_styles#update
    dict(name="custom_styles/update", seed="default", **{"as": D},
         steps=[("PATCH", "/account/custom_styles", {"account[custom_styles]": "body { color: red; }"})], pages=[CSS, CSS, EDIT]),
    dict(name="custom_styles/update/clear", seed="custom_styles", **{"as": D},
         steps=[("PATCH", "/account/custom_styles", {"account[custom_styles]": ""})], pages=[CSS]),
    dict(name="custom_styles/update/member", seed="default", **{"as": K},
         steps=[("PATCH", "/account/custom_styles", {"account[custom_styles]": "body { color: blue; }"})]),

    # accounts/join_codes#create
    dict(name="join_codes/create", seed="default", **{"as": D}, steps=[("POST", "/account/join_code", {})], pages=[EDIT]),
    dict(name="join_codes/create/member", seed="default", **{"as": K}, steps=[("POST", "/account/join_code", {})]),

    # accounts/logos#destroy
    dict(name="logos/destroy", seed="custom_styles", **{"as": D}, settle=6,
         steps=[("DELETE", "/account/logo", {})], pages=[EDIT]),
    dict(name="logos/destroy/no_logo", seed="default", **{"as": D}, settle=3, steps=[("DELETE", "/account/logo", {})], pages=[EDIT]),
    dict(name="logos/destroy/member", seed="custom_styles", **{"as": K}, steps=[("DELETE", "/account/logo", {})]),

    # accounts/users#update
    dict(name="users/update/promote", seed="default", **{"as": D},
         steps=[("PATCH", f"/account/users/{U['kevin']}", {"user[role]": ["member", "administrator"]})], pages=[EDIT]),
    dict(name="users/update/demote", seed="default", **{"as": D},
         steps=[("PATCH", f"/account/users/{U['jason']}", {"user[role]": "member"})], pages=[EDIT]),
    dict(name="users/update/bogus_role", seed="default", **{"as": D},
         steps=[("PATCH", f"/account/users/{U['jason']}", {"user[role]": "owner"})]),
    dict(name="users/update/inactive", seed="default", **{"as": D},
         steps=[("PATCH", f"/account/users/{U['rita']}", {"user[role]": "administrator"})]),
    dict(name="users/update/member", seed="default", **{"as": K},
         steps=[("PATCH", f"/account/users/{U['jz']}", {"user[role]": "administrator"})]),

    # accounts/users#destroy
    dict(name="users/destroy", seed="default", **{"as": D},
         steps=[("DELETE", f"/account/users/{U['kevin']}", {})], pages=[EDIT]),
    dict(name="users/destroy/banned", seed="default", **{"as": D}, steps=[("DELETE", f"/account/users/{U['mallory']}", {})]),
    dict(name="users/destroy/member", seed="default", **{"as": K}, steps=[("DELETE", f"/account/users/{U['jz']}", {})]),

    # accounts/users#index: the next page of the account's people (crowd: more than 500)
    dict(name="users/index/crowd_edit", seed="crowd", **{"as": D}, steps=[], pages=[EDIT]),
    dict(name="users/index/crowd_page2", seed="crowd", **{"as": D}, steps=[],
         pages=["/account/users.turbo_stream?page=2", "/account/users.turbo_stream?page=3", "/account/users.turbo_stream"]),
    dict(name="users/index/member_page", seed="crowd", **{"as": K}, steps=[], pages=["/account/users.turbo_stream?page=2", EDIT]),

    # accounts#update: the name form, the logo forms (a file, no file chosen) and the restrict-room-creation switch
    dict(name="update/name", seed="default", **{"as": D}, steps=[("PATCH", ACCOUNT, {"account[name]": "Renamed"})], pages=[EDIT]),
    dict(name="update/restrict_on", seed="default", **{"as": D},
         steps=[("PUT", ACCOUNT, {"account[settings][restrict_room_creation_to_administrators]": "true"})], pages=[EDIT]),
    dict(name="update/restrict_off", seed="restricted", **{"as": D},
         steps=[("PUT", ACCOUNT, {"account[settings][restrict_room_creation_to_administrators]": "false"})], pages=[EDIT]),
    dict(name="update/restrict_member", seed="default", **{"as": K},
         steps=[("PUT", ACCOUNT, {"account[settings][restrict_room_creation_to_administrators]": "true"})]),
    dict(name="update/logo", seed="default", **{"as": D}, settle=4, steps=[("PATCH", ACCOUNT, {"account[logo]": LOGO})], pages=[EDIT]),
    dict(name="update/logo_replaced", seed="custom_styles", **{"as": D}, settle=6, steps=[("PATCH", ACCOUNT, {"account[logo]": LOGO})], pages=[EDIT]),
    dict(name="update/logo_no_file", seed="default", **{"as": D}, steps=[("PATCH", ACCOUNT, {"account[logo]": NOFILE})], pages=[EDIT]),
]
