// The scoreboard of one parity run (WAVE-PLAN Track CP): which layers each state fails, and the causes behind
// them, clustered across states, so builders can split the work by cause. Reads a fetched run's report.json and
// its reference/ and candidate/ captures; writes nothing.
//
// usage: node test/parity_scoreboard.mjs parity-results/out/compare-...   (pvm-fetch runs it after a fetch)
//
// A cluster is one difference seen in several states: a network request only one server answered ("+" ours,
// "-" the reference's), a request both answered differently ("~"), or a line only one side of a live/aria/server/
// cable capture has. Numbers of three or more digits (not a status) read as N, so the same request to two rooms is
// one cluster.
import fs from "node:fs"
import path from "node:path"

const dir = process.argv[2]
if (!dir || !fs.existsSync(path.join(dir, "report.json"))) {
  console.error("usage: node test/parity_scoreboard.mjs <a compare-* directory holding report.json>")
  process.exit(2)
}
const report = JSON.parse(fs.readFileSync(path.join(dir, "report.json"), "utf8"))
const results = report.results ?? report.cells ?? report.states ?? []
const FILES = { server: "server.norm.html", live: "live.norm.html", aria: "aria.yml", network: "network.txt", cable: "cable.txt" }
const LAYERS = ["server", "pixels", "live", "aria", "network", "cable"]
const generic = (line) => line.trim().replace(/(?<!→ )\b\d{3,}/g, "N")
const read = (target, r, layer) => {
  const file = path.join(dir, target, r.state, `${r.cell}.${FILES[layer]}`)
  return fs.existsSync(file) ? fs.readFileSync(file, "utf8") : ""
}

// network.txt is sorted entries: a request line, then indented header/body lines.
function entries(text) {
  const map = new Map()
  let key
  for (const line of text.split("\n")) {
    if (!line) continue
    if (!line.startsWith(" ")) map.set((key = line), [])
    else if (key) map.get(key).push(line.trim())
  }
  return map
}

function differences(layer, r) {
  const ref = read("reference", r, layer), ours = read("candidate", r, layer)
  const out = new Set()
  if (layer === "network") {
    const a = entries(ref), b = entries(ours)
    for (const [k, v] of a) {
      if (!b.has(k)) out.add(`- ${generic(k)}`)
      else {
        const w = b.get(k)
        const changed = [...v.filter((l) => !w.includes(l)).map((l) => `-${l}`), ...w.filter((l) => !v.includes(l)).map((l) => `+${l}`)]
        if (changed.length) out.add(`~ ${generic(k)}: ${changed.map(generic).join(" | ")}`)
      }
    }
    for (const k of b.keys()) if (!a.has(k)) out.add(`+ ${generic(k)}`)
  } else {
    const a = new Set(ref.split("\n").map(generic).filter(Boolean)), b = new Set(ours.split("\n").map(generic).filter(Boolean))
    for (const l of a) if (!b.has(l)) out.add(`- ${l}`)
    for (const l of b) if (!a.has(l)) out.add(`+ ${l}`)
  }
  return out
}

const counts = report.info?.counts ?? {}
console.log(`# ${path.basename(dir)}: ${Object.entries(counts).map(([k, v]) => `${v} ${k}`).join(", ")}\n`)

const perLayer = Object.fromEntries(LAYERS.map((l) => [l, 0]))
const clusters = new Map()
const rows = []
for (const r of results) {
  const failing = (r.layers ?? []).filter((l) => l.equal === false).map((l) => l.layer)
  failing.forEach((l) => perLayer[l]++)
  rows.push(`${r.status.padEnd(5)} ${r.state}${failing.length ? `  [${failing.join(" ")}]` : ""}${r.error ? `  ${String(r.error).split("\n")[0].slice(0, 140)}` : ""}`)
  for (const layer of failing) {
    if (!FILES[layer]) continue
    for (const d of differences(layer, r)) {
      const key = `${layer} ${d}`
      if (!clusters.has(key)) clusters.set(key, [])
      clusters.get(key).push(r.state)
    }
  }
}

console.log("## Failing layers (states)\n")
console.log(LAYERS.map((l) => `${l} ${perLayer[l]}`).join(" · "), "\n")
console.log("## Causes, by states affected\n")
const sorted = [...clusters.entries()].sort((a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0]))
for (const [key, states] of sorted.slice(0, Number(process.env.SCOREBOARD_TOP ?? 40))) {
  console.log(`${String(states.length).padStart(3)}  ${key.length > 220 ? key.slice(0, 220) + "…" : key}`)
  console.log(`       e.g. ${states.slice(0, 3).join(", ")}${states.length > 3 ? ", …" : ""}`)
}
if (sorted.length > 40) console.log(`\n(${sorted.length - 40} more; SCOREBOARD_TOP=N shows more)`)
console.log("\n## States\n")
console.log(rows.sort().join("\n"))
