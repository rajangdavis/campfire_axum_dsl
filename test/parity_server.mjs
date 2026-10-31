// The server layer of once-campfire-rust's parity check, run locally: our binary on the parity seed, each
// plain-GET state of parity/screens.yml fetched over HTTP (no browser), normalized with the harness's own
// normalize.ts, and diffed against the Rails reference's `server.norm.html` from a VM run (WAVE-PLAN Track CP).
// The harness is imported read-only, never edited. States with steps, several actors, value masks or a
// user_agent need a browser and are skipped; the pixel, live, aria and network layers stay on the VM.
//
// usage: node --experimental-strip-types test/parity_server.mjs CRATE_DIR [GLOB,...]   (the harness's globs: * stops at /, ** does not)
// env:   PARITY_DIR (../once-campfire-rust/parity), PARITY_SEED (test/parity-seed/.seed/default),
//        PARITY_REFERENCE (the VM run's reference/ captures), PARITY_OUT (test/parity-out), PARITY_BIN (the binary;
//        default CRATE_DIR's build under CARGO_TARGET_DIR)
// Writes PARITY_OUT/<state>.server.norm.html and .diff for every state that differs, and prints the diffs themselves
// when at most PARITY_SHOW (3) states differ, since a run in a scratch tree leaves no files behind; exit 1 when any
// state differs.
import fs from "node:fs"
import http from "node:http"
import net from "node:net"
import os from "node:os"
import path from "node:path"
import { spawn, spawnSync } from "node:child_process"

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..")
const crate = path.resolve(process.argv[2] ?? "/tmp/campfire_axum_dsl-out")
const globs = (process.argv[3] ?? "**").split(",")
const parity = path.resolve(root, process.env.PARITY_DIR ?? "../once-campfire-rust/parity")
const seed = path.resolve(root, process.env.PARITY_SEED ?? "test/parity-seed/.seed/default")
const reference = path.resolve(root, process.env.PARITY_REFERENCE ?? "../parity-results/out/compare-2026-10-22T16-46-09-695Z/reference")
const out = path.resolve(root, process.env.PARITY_OUT ?? "test/parity-out")
const cell = "chromium-desktop-light"
// A free port, so parallel runs (one per builder) never share a server.
const port = await new Promise((resolve) => {
  const probe = net.createServer().listen(0, "127.0.0.1", () => { const free = probe.address().port; probe.close(() => resolve(free)) })
})
const base = `http://127.0.0.1:${port}`
// The origin the harness shows the browser for both servers (parity/capture/proxy.ts DEFAULT_ORIGIN): Rails writes
// absolute URLs (a form's action, a redirect) from the request's Host, so every request says this host.
const harnessHost = "localhost:3999"
// The reference's Chromium (its cell .json records browserVersion 153.0.8010.12), as Playwright sends it.
const userAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/153.0.8010.12 Safari/537.36"

const die = (message) => { console.error(`FAIL: ${message}`); process.exit(2) }
// The oldest release of each supported Node line with the 2026-10-21 security fixes (CVE-2026-111497, Brotli
// decoding, and nine more); Node 20, 23 and 25 are end-of-life and get none.
const PATCHED = { 22: "22.23.4", 24: "24.22.1", 26: "26.12.1" }
const older = (a, b) => { const [x, y] = [a, b].map((v) => v.split(".").map(Number)); return x[1] < y[1] || (x[1] === y[1] && x[2] < y[2]) }
const minimum = PATCHED[process.versions.node.split(".")[0]]
if (!minimum || older(process.versions.node, minimum)) {
  die(`Node ${process.versions.node} lacks the 2026-10-21 security fixes; use ${Object.values(PATCHED).join(", ")} or newer in that line`)
}
for (const [what, dir] of [["parity/", parity], ["the seed", seed], ["the reference captures", reference]]) {
  if (!fs.existsSync(dir)) die(`${what} not found at ${dir}`)
}
if (!fs.existsSync(path.join(parity, "node_modules/parse5"))) die(`the harness's packages are not installed: npm ci --prefix ${parity}`)
const bin = process.env.PARITY_BIN ?? [process.env.CARGO_TARGET_DIR, path.join(crate, "target")].filter(Boolean).map((t) => path.join(t, "debug/campfire")).find((f) => fs.existsSync(f))
if (!bin) die(`no campfire binary under CARGO_TARGET_DIR or ${crate}/target; build it first`)

const { normalizeDocument, normalizeResponse } = await import(path.join(parity, "capture/normalize.ts"))
const { loadInventory, interpolate, globToRegExp } = await import(path.join(parity, "capture/inventory.ts"))
const labels = JSON.parse(fs.readFileSync(path.join(seed, "labels.json"), "utf8"))
const seedTime = Date.parse(labels["clock.now"])
// The fixed test-only keys both servers run with (parity/.env.reference).
const env = Object.fromEntries(fs.readFileSync(path.join(parity, ".env.reference"), "utf8").split("\n")
  .filter((line) => /^[A-Z_]+=/.test(line)).map((line) => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)]))

// One HTTP request to our server, sent as the browser sends it to the harness's origin: node:http, because fetch()
// replaces the Host header, and Rails writes absolute URLs from it. No redirect is followed.
function send(method, target, headers = {}, body) {
  return new Promise((resolve, reject) => {
    const request = http.request({ host: "127.0.0.1", port, method, path: target, headers: { ...headers, host: harnessHost } }, (response) => {
      const chunks = []
      response.on("data", (chunk) => chunks.push(chunk))
      response.on("end", () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks) }))
    })
    request.on("error", reject)
    request.end(body)
  })
}

// A page load: redirects followed, as the browser follows them, up to ten.
async function follow(target, headers) {
  for (let hops = 0; hops < 10; hops++) {
    const response = await send("GET", target, headers)
    if (response.status < 300 || response.status >= 400 || !response.headers.location) return response
    const next = new URL(response.headers.location, `http://${harnessHost}`)
    target = next.pathname + next.search
  }
  throw new Error(`more than ten redirects from ${target}`)
}

// A fresh copy of the seed per run: signing in writes session rows.
const work = fs.mkdtempSync(path.join(os.tmpdir(), "parity_server."))
fs.cpSync(path.join(seed, "db"), path.join(work, "db"), { recursive: true })
fs.cpSync(path.join(seed, "storage"), path.join(work, "storage"), { recursive: true })
const server = spawn(bin, [], {
  cwd: crate,
  stdio: ["ignore", "ignore", fs.openSync(path.join(work, "server.log"), "a")],
  env: { ...process.env, PORT: String(port), SECRET_KEY_BASE: env.SECRET_KEY_BASE, VAPID_PUBLIC_KEY: env.VAPID_PUBLIC_KEY, APP_VERSION: env.APP_VERSION,
    DATABASE_PATH: path.join(work, "db/production.sqlite3"), ACTIVE_STORAGE_PATH: path.join(work, "storage") },
})
const stop = () => { server.kill("SIGTERM"); fs.rmSync(work, { recursive: true, force: true }) }
process.on("exit", stop)
for (let i = 0; ; i++) {
  if (await send("GET", "/up").then((r) => r.status === 200, () => false)) break
  if (server.exitCode !== null || i > 200) die(`the server did not come up:\n${fs.readFileSync(path.join(work, "server.log"), "utf8").slice(-2000)}`)
  await new Promise((resolve) => setTimeout(resolve, 100))
}

// One session per fixture user, through the sign-in form as parity/capture/session.ts does.
const sessions = new Map()
async function cookieFor(user) {
  if (!user) return undefined
  if (!sessions.has(user)) {
    const body = new URLSearchParams({
      email_address: String(labels[`emails.${user}`] ?? `${user}@37signals.com`),
      password: String(labels[`passwords.${user}`] ?? labels["passwords.all"] ?? "secret123456"),
    })
    const response = await send("POST", "/session", { "user-agent": userAgent, "sec-fetch-site": "same-origin", origin: `http://${harnessHost}`,
      "content-type": "application/x-www-form-urlencoded" }, body.toString())
    const cookie = (response.headers["set-cookie"] ?? []).map((c) => c.split(";")[0]).filter((c) => c.startsWith("session_token="))
    if (!cookie.length) throw new Error(`sign-in as ${user}: HTTP ${response.status}, no session_token cookie`)
    sessions.set(user, cookie.join("; "))
  }
  return sessions.get(user)
}

// `fetch/<user>/<path>` in place of a state id prints one GET's body as the network layer normalizes it before hashing
// (normalizeResponse), signed in as that fixture user, so a body hash the VM reports can be read and diffed. The user
// `raw` is signed out and also prints the body as sent.
const fetches = globs.filter((glob) => glob.startsWith("fetch/"))
for (const entry of fetches) {
  const [, user, ...rest] = entry.split("/")
  const target = `/${rest.join("/")}`
  const cookie = await cookieFor(user === "raw" ? undefined : user)
  const response = await send("GET", target, { "user-agent": userAgent, accept: "text/html, application/xhtml+xml", ...(cookie ? { cookie } : {}) })
  const type = response.headers["content-type"] ?? ""
  const normalized = normalizeResponse(response.body, type, { seedTime })
  // network.ts hashes the normalized text the same way (the first 16 hex digits of its sha256).
  const hash = (await import("node:crypto")).createHash("sha256").update(normalized).digest("hex").slice(0, 16)
  console.log(`=== GET ${target} as ${user}: HTTP ${response.status} ${type}, body sha256:${hash}\n${normalized}`)
  if (user === "raw") console.log(`=== raw body\n${response.body.toString("utf8")}`)
}
// `refused-login` prints the status and headers of a wrong-password POST /session sent as Turbo's form submission sends
// it (auth/sign_in/error hangs in the browser after this 401; its headers are what the network layer cannot show).
const probes = globs.filter((glob) => glob === "refused-login")
for (const _ of probes) {
  const body = new URLSearchParams({ email_address: String(labels["emails.david"] ?? "david@37signals.com"), password: "wrong-password", log_in: "" })
  const response = await send("POST", "/session", { "user-agent": userAgent, "sec-fetch-site": "same-origin", "sec-fetch-mode": "cors",
    "sec-fetch-dest": "empty", origin: `http://${harnessHost}`, accept: "text/vnd.turbo-stream.html, text/html, application/xhtml+xml",
    "accept-encoding": "gzip, deflate, br, zstd", "x-turbo-request-id": "probe", "content-type": "application/x-www-form-urlencoded" }, body.toString())
  console.log(`=== POST /session (wrong password): HTTP ${response.status}, ${response.body.length} body bytes`)
  const html = (response.headers["content-encoding"] === "gzip" ? (await import("node:zlib")).gunzipSync(response.body) : response.body).toString("utf8")
  console.log(`=== its <head> metas and stylesheet count: ${(html.match(/<link rel="stylesheet"/g) ?? []).length} stylesheets\n${(html.match(/<meta [^>]*>/g) ?? []).join("\n")}`)
  for (const [name, value] of Object.entries(response.headers)) console.log(`${name}: ${[].concat(value).join("\n" + name + ": ")}`)
  // The reload Turbo makes after that 401 is a conditional GET of the form; Rails' page never repeats its ETag.
  const form = await send("GET", "/session/new", { "user-agent": userAgent, accept: "text/html" })
  const again = await send("GET", "/session/new", { "user-agent": userAgent, accept: "text/html", "if-none-match": form.headers.etag ?? "" })
  console.log(`=== GET /session/new: HTTP ${form.status} etag ${form.headers.etag}; again with If-None-Match: HTTP ${again.status} etag ${again.headers.etag}`)
}
// `post/<user>/<path>[/--/<name>.<value>...]` sends one same-origin form POST as that fixture user, the segments after
// `--` as its fields (the hook's parameter allows no `?` or `=`), and prints its status and headers: the network
// layer lists a POST's header names, never their values.
const posts = globs.filter((glob) => glob.startsWith("post/"))
for (const entry of posts) {
  const [, user, ...rest] = entry.split("/")
  const cut = rest.includes("--") ? rest.indexOf("--") : rest.length
  const target = `/${rest.slice(0, cut).join("/")}`
  const form = new URLSearchParams(rest.slice(cut + 1).map((field) => [field.slice(0, field.indexOf(".")), field.slice(field.indexOf(".") + 1)])).toString()
  const cookie = await cookieFor(user)
  const response = await send("POST", target, { "user-agent": userAgent, "sec-fetch-site": "same-origin", origin: `http://${harnessHost}`,
    accept: "text/vnd.turbo-stream.html, text/html, application/xhtml+xml", "content-type": "application/x-www-form-urlencoded", ...(cookie ? { cookie } : {}) }, form)
  console.log(`=== POST ${target} as ${user}: HTTP ${response.status}`)
  for (const [name, value] of Object.entries(response.headers)) console.log(`${name}: ${[].concat(value).join("\n" + name + ": ")}`)
}
if (fetches.length + probes.length + posts.length === globs.length) process.exit(0)
const match = globs.filter((glob) => !glob.startsWith("fetch/")).map((glob) => globToRegExp(glob))
const states = loadInventory(path.join(parity, "screens.yml")).filter((s) => s.seed === "default" && match.some((re) => re.test(s.id)))
fs.rmSync(out, { recursive: true, force: true })
let same = 0, differ = 0, skipped = 0, errors = 0
const diffs = []
for (const state of states) {
  const why = state.steps.length ? "steps" : state.actors ? "actors" : state.masks?.values ? "value masks"
    : state.user_agent ? "user_agent" : typeof state.path !== "string" ? "per-actor path" : null
  const expectedFile = path.join(reference, state.id, `${cell}.server.norm.html`)
  if (why || !fs.existsSync(expectedFile)) {
    skipped++
    console.log(`skip  ${state.id} (${why ?? "no reference capture"})`)
    continue
  }
  let actual
  try {
    const headers = { "user-agent": userAgent, accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", ...state.headers }
    const cookie = await cookieFor(state.as)
    if (cookie) headers.cookie = cookie
    const target = interpolate(state.path, labels, state.id)
    if (state.kind === "fragment") {
      const request = state.request ?? {}
      const response = await send(request.method ?? "GET", target, { ...headers, ...request.headers }, request.body)
      const body = response.body
      const type = response.headers["content-type"] ?? ""
      const location = response.headers["location"]
      const head = [`HTTP ${response.status}`, `content-type: ${type}`, ...(location ? [`location: ${location}`] : [])]
      actual = `${head.join("\n")}\n\n${normalizeResponse(body, type, { seedTime })}`
    } else {
      const response = await follow(target, headers)
      const wanted = state.expect_status ?? 200
      if (response.status !== wanted) console.log(`      ${state.id}: HTTP ${response.status}, the reference answers ${wanted}`)
      actual = normalizeDocument(response.body.toString("utf8"), { seedTime })
    }
  } catch (error) {
    errors++
    console.log(`ERROR ${state.id}: ${String(error).split("\n")[0]}`)
    continue
  }
  const expected = fs.readFileSync(expectedFile, "utf8")
  if (actual === expected) {
    same++
    console.log(`same  ${state.id}`)
    continue
  }
  differ++
  const actualFile = path.join(out, `${state.id}.server.norm.html`)
  fs.mkdirSync(path.dirname(actualFile), { recursive: true })
  fs.writeFileSync(actualFile, actual)
  const diff = spawnSync("diff", ["-u", "--label", "reference", "--label", "ours", expectedFile, actualFile], { encoding: "utf8" }).stdout
  fs.writeFileSync(path.join(out, `${state.id}.diff`), diff)
  diffs.push([state.id, diff])
  const lines = diff.split("\n").slice(2)
  const added = lines.filter((l) => l.startsWith("+")).length, removed = lines.filter((l) => l.startsWith("-")).length
  console.log(`DIFF  ${state.id} (+${added} -${removed}, ${path.relative(root, path.join(out, `${state.id}.diff`))})`)
}
if (diffs.length <= Number(process.env.PARITY_SHOW ?? 3)) {
  for (const [id, diff] of diffs) console.log(`\n=== ${id}\n${diff.split("\n").filter((l) => !l.startsWith(" ")).map((l) => (l.length > 150 ? `${l.slice(0, 150)}…` : l)).reduce((acc, l) => { if (l.startsWith("@@")) acc.n = 0; if (++acc.n <= 8) acc.push(l); else if (acc.n === 9) acc.push("  … (rest of hunk omitted)"); return acc }, Object.assign([], { n: 0 })).join("\n")}`)
}
console.log(`${states.length} states: ${same} same, ${differ} differ, ${errors} error, ${skipped} skipped (need a browser or have no reference capture)`)
process.exit(differ || errors ? 1 : 0)

