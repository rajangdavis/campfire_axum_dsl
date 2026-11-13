#!/usr/bin/env python3
"""run.py SCENARIO_FILE [NAME...]: replay writes against Rails and the port, each on a fresh copy of a parity seed.

A scenario file is Python defining SCENARIOS = [ {name, seed, as, steps, pages, after} ]:
  as      the e-mail address to sign in as (password `secret123456`), or None
  steps   [(METHOD, PATH, {field: value or [values]})]; a dict value of ("file", path) uploads a file
  pages   paths fetched after the steps and compared as DOM trees (domdiff's masking)
For each step the status and Location are compared; after the steps every table's rows are compared with timestamps,
digests and random tokens masked. Exit 1 on any difference."""
import http.cookiejar, json, os, re, subprocess, sys, urllib.parse, urllib.request, uuid, sqlite3

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PARITY = os.path.abspath(os.environ.get("PARITY_DIR", os.path.join(ROOT, "../once-campfire-rust/parity")))
RAILS, PORT = 3101, 4501
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
SKIP_TABLES = {"ar_internal_metadata", "schema_migrations", "message_search_index_data", "message_search_index_idx",
               "message_search_index_docsize", "message_search_index_config", "message_search_index_content"}
MASKS = [(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d+)?", "<ts>"), (r"\$2[ab]\$12\$[./A-Za-z0-9]{53}", "<bcrypt>"),
         (r"^[1-9A-HJ-NP-Za-km-z]{24}$", "<token>"), (r"^[A-Za-z0-9]{4}-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}$", "<code>"),
         (r"^(127\.0\.0\.1|172\.17\.0\.1)$", "<ip>"), (r"^[a-z0-9]{28}$", "<blobkey>"),
         (r"-deactivated-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}@", "-deactivated-<uuid4>@")]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


class Client:
    def __init__(self, port):
        self.port, self.jar, self.csrf = port, http.cookiejar.CookieJar(), ""
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar), NoRedirect)

    def send(self, method, path, fields=None, extra=None):
        url = f"http://127.0.0.1:{self.port}{path}"
        extra = dict(extra or {})
        # Turbo's form submissions also accept a turbo stream, which is what MessagesController#create answers with.
        default_accept = "text/html, application/xhtml+xml" if method == "GET" else "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"
        headers = {"User-Agent": UA, "Accept": extra.pop("Accept", None) or default_accept, "Sec-Fetch-Site": "same-origin",
                   "Origin": f"http://127.0.0.1:{self.port}", "X-CSRF-Token": self.csrf, **(extra or {})}
        data = None
        # a raw body sent with the real verb, as a bot's curl does (no CSRF, no _method); ("multipart", {fields}) is
        # curl's -F, a multipart body (a ("file", path) value is a file part)
        if isinstance(fields, bytes) or (isinstance(fields, tuple) and fields[0] == "multipart"):
            raw, raw_type = (fields, "application/x-www-form-urlencoded") if isinstance(fields, bytes) else multipart(fields[1])
            req = urllib.request.Request(url, data=raw, headers={"User-Agent": "curl/8.5.0", "Accept": "*/*",
                                                                 "Content-Type": raw_type}, method=method)
            try:
                r = urllib.request.build_opener(NoRedirect).open(req, timeout=60)  # no cookies: a bot's curl has none
            except urllib.error.HTTPError as e:
                r = e
            body = r.read()
            return r.status, re.sub(r"http://127\.0\.0\.1:\d+", "", r.headers.get("Location") or ""), r.headers.get("Content-Type", ""), body
        if method != "GET":
            fields = dict(fields or {})
            if method not in ("POST",):
                fields["_method"] = method.lower()
            fields.setdefault("authenticity_token", self.csrf)
            if any(isinstance(v, tuple) for v in fields.values()):
                data, ctype = multipart(fields)
            else:
                pairs = [(k, x) for k, v in fields.items() for x in (v if isinstance(v, list) else [v])]
                data, ctype = urllib.parse.urlencode(pairs).encode(), "application/x-www-form-urlencoded"
            headers["Content-Type"] = ctype
        req = urllib.request.Request(url, data=data, headers=headers, method="GET" if method == "GET" else "POST")
        try:
            r = self.op.open(req, timeout=60)
        except urllib.error.HTTPError as e:
            r = e
        body = r.read()
        loc = re.sub(r"http://127\.0\.0\.1:\d+", "", r.headers.get("Location") or "")
        token = re.search(rb'name="csrf-token" content="([^"]+)"', body)
        if token:
            self.csrf = token.group(1).decode()
        return r.status, loc, r.headers.get("Content-Type", ""), body

    def login(self, email):
        _, _, _, body = self.send("GET", "/session/new")
        tok = re.search(rb'name="authenticity_token" value="([^"]+)"', body)
        self.csrf = tok.group(1).decode() if tok else ""
        s, loc, _, _ = self.send("POST", "/session", {"email_address": email, "password": "secret123456"})
        assert s == 302, f"login as {email} on {self.port}: {s}"
        self.send("GET", "/account/edit")  # a signed-in page, for the csrf-token meta


def multipart(fields):
    b = "differentialboundary7MA4YWxkTrZu0gW"  # fixed, so a raw multipart body is the same text on both servers
    out = []
    for k, v in fields.items():
        for x in (v if isinstance(v, list) else [v]):
            if isinstance(x, tuple):
                name = os.path.basename(x[1]) if x[1] else ""
                content = open(x[1], "rb").read() if x[1] else b""
                ctype = "image/png" if name.endswith(".png") else "application/octet-stream"
                out.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"; filename="{name}"\r\nContent-Type: {ctype}\r\n\r\n'.encode() + content + b"\r\n")
            else:
                out.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{x}\r\n'.encode())
    return b"".join(out) + f"--{b}--\r\n".encode(), f"multipart/form-data; boundary={b}"


# A/B mode: REFERENCE_BIN (with REFERENCE_CRATE, its crate folder) runs an earlier build of the port in Rails' place,
# so a refactor is checked against the build before it, scenario for scenario, with no Rails image.
AB = os.environ.get("REFERENCE_BIN")
AB_DATA = "/tmp/campfire-differential-ab"


def start(seed):
    if AB:
        env = dict(os.environ, CANDIDATE_BIN=AB, CANDIDATE_CRATE=os.environ.get("REFERENCE_CRATE", "/tmp/campfire_before-out"),
                   CANDIDATE_DATA=AB_DATA)
        env.pop("CANDIDATE_DOCKER", None)
        subprocess.run([f"{HERE}/candidate.sh", seed, str(RAILS)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    else:
        subprocess.run([f"{PARITY}/bin/reference", "down", "--port", str(RAILS)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([f"{PARITY}/bin/reference", "up", "--seed", seed, "--port", str(RAILS)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    subprocess.run([f"{HERE}/candidate.sh", seed, str(PORT)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)


PAGE_MASKS = []  # and for the pages
EXTRA = []  # a scenario's own masks, for the values it makes at random (a bot token)


def rows(db):
    c = sqlite3.connect(db)
    out = {}
    for (t,) in c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"):
        if t in SKIP_TABLES or t.startswith("axum_dsl_"):
            continue
        cols = [r[1] for r in c.execute(f'PRAGMA table_info("{t}")')]
        order = "id" if "id" in cols else "rowid"
        out[t] = [dict(zip(cols, [mask(v) for v in r])) for r in c.execute(f'SELECT * FROM "{t}" ORDER BY {order}')]
    return out


def mask(v):
    if isinstance(v, str):
        for pat, rep in MASKS + EXTRA:
            v = re.sub(pat, rep, v)
    return v


def domdiff(a, b):
    open("/tmp/wc_a.html", "wb").write(a)
    open("/tmp/wc_b.html", "wb").write(b)
    json.dump(PAGE_MASKS, open("/tmp/wc_masks.json", "w"))
    r = subprocess.run([sys.executable, f"{HERE}/domdiff.py", "/tmp/wc_a.html", "/tmp/wc_b.html", "24"], capture_output=True, text=True,
                       env=dict(os.environ, DOMDIFF_MASKS="/tmp/wc_masks.json"))
    return r.returncode == 0, r.stdout


STARTED = [None]
CLIENTS = {}


def run(sc):
    EXTRA[:] = sc.get("masks", [])
    PAGE_MASKS[:] = sc.get("page_masks", [])
    if not (sc.get("reuse") and STARTED[0] == sc["seed"]):
        start(sc["seed"])
        CLIENTS.clear()
    STARTED[0] = sc["seed"]
    if sc.get("reuse") and CLIENTS.get(sc.get("as")):
        a, b = CLIENTS[sc.get("as")]
    else:
        a, b = Client(RAILS), Client(PORT)
        if sc.get("as"):
            a.login(sc["as"]), b.login(sc["as"])
        CLIENTS.clear()
        CLIENTS[sc.get("as")] = (a, b)
    bad = []
    for step in sc["steps"]:
        method, path, fields = step[:3]
        extra = step[3] if len(step) > 3 else None  # the request's own headers (a turbo-stream Accept)
        ra, rb = a.send(method, path, fields, extra), b.send(method, path, fields, extra)
        line = f"{method} {path}: rails {ra[0]} {ra[1]} | port {rb[0]} {rb[1]}"
        same = ra[:2] == rb[:2]
        if sc.get("bodies") and same and (ra[2], ra[3]) != (rb[2], rb[3]):  # the answer itself (a JSON API)
            same = False
            line += f"\n       rails {ra[2]} {ra[3][:600]!r}\n       port  {rb[2]} {rb[3][:600]!r}"
        print(("  ok   " if same else "  DIFF ") + line)
        if not same:
            bad.append(line)
            if rb[0] >= 400:
                print("       port body:", rb[3][:200])
    if sc.get("settle"):  # Rails' background jobs (purge_later and the like) run after the response
        import time
        time.sleep(sc["settle"])
    ref_db = f"{AB_DATA}-{RAILS}/db/production.sqlite3" if AB else f"{PARITY}/.seed/.instances/{RAILS}/db/production.sqlite3"
    ta, tb = rows(ref_db), rows(f"{os.environ.get('CANDIDATE_DATA', '/tmp/campfire-differential')}-{PORT}/db/production.sqlite3")
    for t in sorted(set(ta) | set(tb)):
        if ta.get(t) != tb.get(t):
            ra_, rb_ = ta.get(t, []), tb.get(t, [])
            only_a = [r for r in ra_ if r not in rb_][:3]
            only_b = [r for r in rb_ if r not in ra_][:3]
            print(f"  DIFF table {t}: rails {len(ra_)} rows, port {len(rb_)}\n       rails only: {only_a}\n       port only:  {only_b}")
            bad.append(f"table {t}")
    for p in sc.get("pages", []):
        # A page given as (path, frame) is fetched as that Turbo frame, the way the browser loads it.
        path, extra = (p[0], {"Turbo-Frame": p[1]}) if isinstance(p, tuple) else (p, None)
        pa, pb = a.send("GET", path, None, extra), b.send("GET", path, None, extra)
        same, out = domdiff(pa[3], pb[3])
        same = same and pa[0] == pb[0]
        print(("  ok   " if same else "  DIFF ") + f"page {p} ({pa[0]} vs {pb[0]})")
        if not same:
            print("       " + out.replace("\n", "\n       ")[:3000])
            bad.append(f"page {p}")
    return bad


def main():
    ns = {"__file__": os.path.abspath(sys.argv[1])}
    exec(open(sys.argv[1]).read(), ns)
    names = set(sys.argv[2:])
    failed = 0
    for sc in ns["SCENARIOS"]:
        if names and sc["name"] not in names:
            continue
        print(f"## {sc['name']}")
        bad = run(sc)
        print(f"  -> {'PASS' if not bad else 'FAIL (' + str(len(bad)) + ')'}")
        failed += bool(bad)
    sys.exit(1 if failed else 0)


main()
