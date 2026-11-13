"""domdiff.py A B: compare two HTML documents as trees (tag, sorted attributes, whitespace-collapsed text).
Masks the per-request CSRF values. Prints the first differences with their paths; exit 1 when they differ."""
import sys, re
from html.parser import HTMLParser

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
MASK = {("meta", "content", "csrf-token"), ("input", "value", "authenticity_token")}


class P(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out, self.stack = [], []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        for t, attr, name in MASK:
            if tag == t and (a.get("name") == name):
                a[attr] = "<csrf>"
        if tag == "input" and a.get("name") == "authenticity_token":
            return  # Rails' form_with writes it; the port's forms do not need one (the harness ignores it too)
        path = "/".join(self.stack + [tag])
        self.out.append((path, "<" + tag + " " + " ".join(f'{k}="{v}"' for k, v in sorted(a.items())) + ">"))
        if tag not in VOID:
            self.stack.append(tag)

    handle_startendtag = handle_starttag

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if tag in self.stack:
            while self.stack and self.stack.pop() != tag:
                pass

    def handle_data(self, d):
        d = re.sub(r"\s+", " ", d).strip()
        if d:
            self.out.append(("/".join(self.stack), d))


# Values that differ by clock, port or randomness between two fresh servers.
NOISE = [(r"127\.0\.0\.1:\d+", "HOST"), (r"\?v=\d{14}", "?v=<ts>"), (r"/join/[A-Za-z0-9]{4}-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}", "/join/<code>"),
         (r"/qr_code/[A-Za-z0-9_=-]+", "/qr_code/<b64>"), (r"/session/transfers/[A-Za-z0-9_=-]+--[0-9a-f]+", "/session/transfers/<signed>")]


import json, os
EXTRA_NOISE = json.load(open(os.environ["DOMDIFF_MASKS"])) if os.environ.get("DOMDIFF_MASKS") else []


def tree(path):
    p = P()
    text = open(path, encoding="utf-8", errors="replace").read()
    for pat, rep in NOISE + [tuple(x) for x in EXTRA_NOISE]:
        text = re.sub(pat, rep, text)
    # An epoch-milliseconds value from this run's clock (a row written by the test, a page's load time) differs by the
    # milliseconds between the two servers; seeded values are older and still compared.
    import time
    now = time.time() * 1000
    text = re.sub(r'="(\d{13})"', lambda m: '="<now-ms>"' if abs(int(m.group(1)) - now) < 3600_000 else m.group(0), text)
    import datetime
    def iso_now(m):
        try:
            t = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp() * 1000
        except ValueError:
            return m.group(0)
        return '="<now-iso>"' if abs(t - now) < 3600_000 else m.group(0)
    text = re.sub(r'="(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)"', iso_now, text)
    p.feed(text)
    return p.out


a, b = tree(sys.argv[1]), tree(sys.argv[2])
import difflib
diff = [l for l in difflib.unified_diff([f"{p}  {x}" for p, x in a], [f"{p}  {x}" for p, x in b], "rails", "port", n=1, lineterm="")]
if not diff:
    print(f"identical ({len(a)} nodes)")
    sys.exit(0)
print("\n".join(diff[:int(sys.argv[3]) if len(sys.argv) > 3 else 60]))
sys.exit(1)
