D, K = "david@37signals.com", "kevin@37signals.com"
PUSH = "/users/me/push_subscriptions"
FCM = "https://fcm.googleapis.com/fcm/send/new-endpoint"

SCENARIOS = [
    # users/push_subscriptions#create: an existing endpoint is touched (when it still validates), a new one created
    dict(name="push/create/new", seed="default", **{"as": D},
         steps=[("POST", PUSH, {"push_subscription[endpoint]": FCM, "push_subscription[p256dh_key]": "BKEY", "push_subscription[auth_key]": "AKEY"})], pages=[PUSH]),
    dict(name="push/create/existing", seed="default", **{"as": D},
         steps=[("POST", PUSH, {"push_subscription[endpoint]": "https://fcm.googleapis.com/fcm/send/123", "push_subscription[p256dh_key]": "123-RIXcMgkdjhRnFZaYjjGvo00dydRQbCpQTuXFjLaCPSE7ofxi19awgGc3Doqa1RmYQqsbQDfQTifFZgc", "push_subscription[auth_key]": "xxx2DtgvmLkevKRwoyahJl0efg"})]),
    dict(name="push/create/http", seed="default", **{"as": D},
         steps=[("POST", PUSH, {"push_subscription[endpoint]": "http://fcm.googleapis.com/x", "push_subscription[p256dh_key]": "B", "push_subscription[auth_key]": "A"})]),
    dict(name="push/create/host", seed="default", **{"as": D},
         steps=[("POST", PUSH, {"push_subscription[endpoint]": "https://evil.example.com/x", "push_subscription[p256dh_key]": "B", "push_subscription[auth_key]": "A"})]),
    dict(name="push/create/port", seed="default", **{"as": D},
         steps=[("POST", PUSH, {"push_subscription[endpoint]": "https://fcm.googleapis.com:8443/x", "push_subscription[p256dh_key]": "B", "push_subscription[auth_key]": "A"})]),
    dict(name="push/create/subdomain", seed="default", **{"as": D},
         steps=[("POST", PUSH, {"push_subscription[endpoint]": "https://eu.notify.windows.com/w/abc", "push_subscription[p256dh_key]": "B", "push_subscription[auth_key]": "A"})]),
    dict(name="push/create/blank", seed="default", **{"as": D},
         steps=[("POST", PUSH, {"push_subscription[endpoint]": "", "push_subscription[p256dh_key]": "B", "push_subscription[auth_key]": "A"})]),
    # users/push_subscriptions#destroy: only the person's own (another's is a no-op), then back to the list
    dict(name="push/destroy", seed="default", **{"as": D}, steps=[("DELETE", f"{PUSH}/56887440", {})], pages=[PUSH]),
    dict(name="push/destroy/missing", seed="default", **{"as": D}, steps=[("DELETE", f"{PUSH}/1", {})]),
    # searches#clear
    dict(name="searches/clear", seed="default", **{"as": D}, steps=[("DELETE", "/searches/clear", {})], pages=["/searches"]),
    dict(name="searches/clear/none", seed="default", **{"as": K}, steps=[("DELETE", "/searches/clear", {})], pages=["/searches"]),
    # users/push_subscriptions/test_notifications#create
    dict(name="push/test_notification", seed="default", **{"as": D}, steps=[("POST", f"{PUSH}/56887440/test_notifications", {})]),
    dict(name="push/test_notification/not_own", seed="default", **{"as": D}, steps=[("POST", f"{PUSH}/257765087/test_notifications", {})]),
]
