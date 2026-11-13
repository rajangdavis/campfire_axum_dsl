#!/usr/bin/env python3
"""Every write the pages can send, replayed against Rails and the candidate, so a missing route shows as a number.

The parity run's Rails captures (PARITY_REFERENCE/**/*.server.norm.html) hold the pages exactly as both servers render
them (the server layer of parity passes), so their forms are the complete list of what a browser can submit: each
form's action, its method or hidden `_method`, and its own fields; `data-turbo-method` links count too. Each one is
sent to the reference and to the candidate, both started on their own copy of the parity seed and signed in as the
same administrator, and the answers are compared: status and the Location path. A route the reference answers and
the candidate 404s or 405s is MISSING; any other difference is MISMATCH. Exit status 1 when anything is missing.

usage: test/write_routes.py [--reference-image campfire-reference:app] [--candidate-image once-campfire-axum-dsl:app]
env:   PARITY_DIR (../once-campfire-rust/parity), PARITY_REFERENCE (a compare run's reference/ dir), PARITY_SEED
       (PARITY_DIR/.seed/default). Needs docker; run as the uid the images write their database as (1000).
"""
import argparse, glob, html.parser, http.cookiejar, json, os, re, shutil, subprocess, sys, tempfile, time
import urllib.error, urllib.parse, urllib.request

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
parity = os.path.abspath(os.environ.get("PARITY_DIR", os.path.join(root, "../once-campfire-rust/parity")))
seed = os.path.abspath(os.environ.get("PARITY_SEED", os.path.join(parity, ".seed/default")))
reference = os.environ.get("PARITY_REFERENCE") or max(glob.glob(os.path.join(parity, "out/compare-*/reference")), default="")
ap = argparse.ArgumentParser()
ap.add_argument("--reference-image", default="campfire-reference:app")
ap.add_argument("--candidate-image", default="once-campfire-axum-dsl:app")
args = ap.parse_args()
if not os.path.isdir(reference):
    sys.exit(f"FAIL: no reference captures; set PARITY_REFERENCE (looked in {parity}/out/compare-*/reference)")


class Forms(html.parser.HTMLParser):
    """Each form's (method, action, fields) and each data-turbo-method link's (method, href, [])."""

    def __init__(self):
        super().__init__()
        self.found, self.form = [], None

    def handle_starttag(self, tag, a):
        a = dict(a)
        if tag == "form":
            self.form = {"method": (a.get("method") or "get").upper(), "action": a.get("action") or "", "fields": []}
        elif self.form is not None and tag in ("input", "textarea", "select", "button") and a.get("name"):
            if tag == "input" and a.get("type") in ("checkbox", "radio") and "checked" not in a:
                return
            if tag == "button" and a.get("type") not in (None, "submit"):
                return
            self.form["fields"].append((a["name"], a.get("value") or ""))
        elif tag == "a" and a.get("data-turbo-method"):
            self.found.append((a["data-turbo-method"].upper(), a.get("href") or "", []))

    def handle_endtag(self, tag):
        if tag == "form" and self.form is not None:
            f, self.form = self.form, None
            override = [v for k, v in f["fields"] if k == "_method"]
            fields = [(k, v) for k, v in f["fields"] if k not in ("_method", "authenticity_token")]
            self.found.append(((override[0] if override else f["method"]).upper(), f["action"], fields))


# One request per (method, route shape): the first capture that shows it, with its real ids from the seed.
requests = {}
for path in sorted(glob.glob(os.path.join(reference, "**/*.server.norm.html"), recursive=True)):
    p = Forms()
    p.feed(open(path, encoding="utf-8", errors="replace").read())
    for method, action, fields in p.found:
        action = re.sub(r"^https?://[^/]+", "", action)
        if method == "GET" or not action.startswith("/") or "«" in action:  # «...» = a value the harness masked
            continue
        if action in ("/session",) or action.startswith("/join/"):  # signing in or out would end the run's session
            continue
        shape = (method, re.sub(r"\d+", "N", action.split("?")[0]))
        requests.setdefault(shape, (method, action, fields, os.path.relpath(path, reference).split("/chromium")[0]))
# Destructive requests last, so the rest run against the seed as captured.
order = sorted(requests.values(), key=lambda r: (r[0] == "DELETE", r[1]))

env_file = os.path.join(parity, ".env.reference")
labels = json.load(open(os.path.join(seed, "labels.json")))
work = tempfile.mkdtemp(prefix="write-routes-")


def start(name, image, port):
    data = os.path.join(work, name)
    for sub, src in (("db", "db"), ("files", "storage")):
        shutil.copytree(os.path.join(seed, src), os.path.join(data, sub))
    os.makedirs(os.path.join(data, "logs"))
    subprocess.run(["chmod", "-R", "a+rwX", data], check=True)
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)
    subprocess.run(["docker", "run", "-d", "--name", name, "--network", "host", "--env-file", env_file,
                    "-e", f"HTTP_PORT={port}", "-e", f"TARGET_PORT={port + 100}", "-e", "DISABLE_SSL=true",
                    "-v", f"{data}/db:/rails/storage/db", "-v", f"{data}/files:/rails/storage/files",
                    "-v", f"{data}/logs:/rails/storage/logs", image], check=True, capture_output=True)
    for _ in range(120):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/up", timeout=2)
            return f"http://127.0.0.1:{port}"
        except Exception:
            time.sleep(0.5)
    print(subprocess.run(["docker", "logs", name], capture_output=True, text=True).stderr[-1500:], file=sys.stderr)
    sys.exit(f"FAIL: {image} did not answer /up on :{port}")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


class Client:
    def __init__(self, base):
        self.base, self.jar = base, http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar), NoRedirect)
        self.csrf = ""
        page = self.send("GET", "/session/new")[2]
        token = re.search(r'name="authenticity_token" value="([^"]+)"', page)
        status = self.send("POST", "/session", [("email_address", labels["emails.david"]), ("password", labels["passwords.all"])]
                           + ([("authenticity_token", token.group(1))] if token else []))[0]
        if status != 302:
            sys.exit(f"FAIL: sign-in on {base} answered {status}")
        meta = re.search(r'name="csrf-token" content="([^"]+)"', self.send("GET", "/")[2] or self.send("GET", "/users/me/profile")[2])
        self.csrf = meta.group(1) if meta else ""

    def send(self, method, path, fields=None):
        data = None
        if method != "GET":
            fields = list(fields or [])
            if method not in ("POST",):
                fields.append(("_method", method.lower()))
            data = urllib.parse.urlencode(fields).encode()
        req = urllib.request.Request(self.base + path, data=data, method="GET" if method == "GET" else "POST")
        req.add_header("Sec-Fetch-Site", "same-origin")
        req.add_header("Origin", self.base)
        req.add_header("Accept", "text/html, application/xhtml+xml")
        if self.csrf:
            req.add_header("X-CSRF-Token", self.csrf)
        try:
            r = self.opener.open(req, timeout=30)
            return r.status, "", r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            loc = urllib.parse.urlparse(e.headers.get("Location") or "").path
            return e.code, loc, ""


try:
    ref = Client(start("write-routes-reference", args.reference_image, 4211))
    cand = Client(start("write-routes-candidate", args.candidate_image, 4212))
    missing = mismatch = 0
    for method, action, fields, state in order:
        (rs, rl, _), (cs, cl, _) = ref.send(method, action, fields), cand.send(method, action, fields)
        # A created record's id depends on what was created before it, so ids in a redirect are not compared.
        same = rs == cs and re.sub(r"\d+", "N", rl) == re.sub(r"\d+", "N", cl)
        kind = "ok" if same else ("MISSING" if rs < 500 and rs not in (404, 405) and cs in (404, 405) else "MISMATCH")
        missing += kind == "MISSING"
        mismatch += kind == "MISMATCH"
        print(f"{kind:8} {method:6} {action:58} reference={rs} {rl:28} candidate={cs} {cl}   [{state}]")
    print(f"\n{len(order)} writes: {missing} missing, {mismatch} other differences")
    sys.exit(1 if missing else 0)
finally:
    for name in ("write-routes-reference", "write-routes-candidate"):
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)
    shutil.rmtree(work, ignore_errors=True)
