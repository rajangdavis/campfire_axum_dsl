#!/usr/bin/env python3
"""webhooks_compare.py LOG: for each scenario (the `case` query parameter), the payload Rails sent (from a Docker
address) against the one the port sent (from the host), as parsed JSON. Exit 1 when one is missing or they differ."""
import json, sys, urllib.parse
seen = {}
for line in open(sys.argv[1]):
    e = json.loads(line)
    case = urllib.parse.parse_qs(urllib.parse.urlparse(e["path"]).query).get("case", ["?"])[0]
    # Rails runs in Docker (172.17.0.x); the port's request comes from the host, or through the sandbox's egress
    # (192.0.2.2) where one intercepts it.
    side = "port" if e["peer"] in ("127.0.0.1", "172.17.0.1", "192.0.2.2") else "rails"
    seen.setdefault(case, {}).setdefault(side, []).append(e)
bad = 0
for case, sides in sorted(seen.items()):
    a, b = sides.get("rails", []), sides.get("port", [])
    # Parsed and in key order: Rails' to_json writes user, room, message as Webhook#payload lists them.
    order = lambda xs: [json.dumps(x["body"]) for x in xs]
    same = order(a) == order(b) and [x["type"] for x in a] == [x["type"] for x in b]
    print(("ok   " if same else "DIFF ") + f"{case}: rails {len(a)}, port {len(b)}")
    if not same:
        bad += 1
        print("  rails:", json.dumps([(x["type"], x["body"]) for x in a])[:900])
        print("  port: ", json.dumps([(x["type"], x["body"]) for x in b])[:900])
sys.exit(1 if bad else 0)
