import os
AV = ("file", os.path.join(os.path.dirname(os.path.abspath(__file__)), "avatar.png"))
NOFILE = ("file", "")
FORM = {"user[name]": "Ada Admin", "user[email_address]": "ada@example.com", "user[password]": "secret123456"}
# What a first run makes at random: the join code and the session token (masked by run.py), nothing else.
SCENARIOS = [
    dict(name="first_run/show", seed="first_run", steps=[], pages=["/first_run", "/session/new", "/"]),
    dict(name="first_run/create", seed="first_run",
         steps=[("GET", "/first_run", None), ("POST", "/first_run", {**FORM, "user[avatar]": NOFILE})],
         pages=["/", "/first_run", "/account/edit", "/users/me/profile"]),
    dict(name="first_run/create/avatar", seed="first_run", settle=3,
         steps=[("GET", "/first_run", None), ("POST", "/first_run", {**FORM, "user[avatar]": AV})], pages=["/users/me/profile"]),
    dict(name="first_run/after_setup", seed="default", **{"as": "david@37signals.com"},
         steps=[("GET", "/first_run", None), ("POST", "/first_run", {**FORM, "user[avatar]": NOFILE})]),
]
