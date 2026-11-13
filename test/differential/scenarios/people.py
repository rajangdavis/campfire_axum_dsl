D, K, J = "david@37signals.com", "kevin@37signals.com", "jason@37signals.com"
U = dict(david=127326141, jason=149087659, kevin=712064548, jz=773523953, mallory=773523955, rita=773523954, bender=394959859, deploy=773523956)
UUID = [(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", "<uuid4>")]

SCENARIOS = [
    # users/bans#create: the person is banned, signed out, and their messages go (RemoveBannedContentJob)
    dict(name="bans/create", seed="default", **{"as": D}, settle=6,
         steps=[("POST", f"/users/{U['kevin']}/ban", {})], pages=[f"/users/{U['kevin']}", "/rooms/201306877"]),
    dict(name="bans/create/admin_target", seed="default", **{"as": D}, settle=6,
         steps=[("POST", f"/users/{U['jason']}/ban", {})], pages=[f"/users/{U['jason']}"]),
    dict(name="bans/create/member", seed="default", **{"as": K}, steps=[("POST", f"/users/{U['jz']}/ban", {})]),
    dict(name="bans/create/unknown", seed="default", **{"as": D}, steps=[("POST", "/users/1/ban", {})]),
    # users/bans#destroy
    dict(name="bans/destroy", seed="default", **{"as": D},
         steps=[("DELETE", f"/users/{U['mallory']}/ban", {})], pages=[f"/users/{U['mallory']}"]),
    dict(name="bans/destroy/not_banned", seed="default", **{"as": D}, steps=[("DELETE", f"/users/{U['jz']}/ban", {})]),
    dict(name="bans/destroy/member", seed="default", **{"as": K}, steps=[("DELETE", f"/users/{U['mallory']}/ban", {})]),
    # users/avatars#destroy: always the signed-in person's own avatar, whatever the path's id
    dict(name="avatars/destroy", seed="default", **{"as": J}, settle=6,
         steps=[("DELETE", f"/users/{U['jason']}/avatar", {})], pages=["/users/me/profile"]),
    dict(name="avatars/destroy/someone_else", seed="default", **{"as": J}, settle=6,
         steps=[("DELETE", f"/users/{U['deploy']}/avatar", {})], pages=["/users/me/profile"]),
    dict(name="avatars/destroy/none", seed="default", **{"as": D}, settle=3,
         steps=[("DELETE", f"/users/{U['david']}/avatar", {})], pages=["/users/me/profile"]),
    # Message#destroy purges its attachment's blob (and its variants, and a video's preview) after the response.
    dict(name="messages/destroy/with_file", seed="default", **{"as": D}, settle=6,
         steps=[("DELETE", "/rooms/654632876/messages/933434498", {}, {"Accept": "text/vnd.turbo-stream.html, text/html"})]),
    dict(name="messages/destroy/with_video", seed="default", **{"as": D}, settle=6,
         steps=[("DELETE", "/rooms/654632876/messages/933434500", {}, {"Accept": "text/vnd.turbo-stream.html, text/html"})]),
]
