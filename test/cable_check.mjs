// The Action Cable layer of the Campfire e2e (campfire.axum.rb's `cable "/cable"`), driven over a real
// WebSocket with node alone: sign in, read the room page for the Turbo signed stream name it renders, then
// speak actioncable-v1-json. The check is the readiness contract the parity harness waits for
// (once-campfire-rust/parity/capture/readiness.ts: the socket open; every subscription confirmed or rejected):
//
//   - welcome, then a ping within about 3 s;
//   - confirm_subscription for each of the six app channels and Turbo's two room-list streams;
//   - reject_subscription for a channel the endpoint does not declare;
//   - disconnect with reason "unauthorized" (and reconnect: false) with no session cookie.
//
// It expects the service test/e2e_campfire.sh already started on its own seeded database, at CABLE_BASE or
// http://127.0.0.1:8099. CABLE_COOKIE reuses that script's session; without it the check signs in as the seed's
// david@37signals.com. No package: the WebSocket client below is the small RFC 6455 subset the check needs.
// usage: node test/cable_check.mjs [BASE_URL]
import crypto from "node:crypto"
import http from "node:http"

const base = process.argv[2] ?? process.env.CABLE_BASE ?? "http://127.0.0.1:8099"
const origin = new URL(base)
const host = origin.hostname
const port = Number(origin.port || 80)
const PROTOCOL = "actioncable-v1-json"
const email = process.env.CABLE_EMAIL ?? "david@37signals.com"
const password = process.env.CABLE_PASSWORD ?? "campfire-test-pw"

let failed = 0
const ok = (text) => console.log(`ok: ${text}`)
const bad = (error) => {
  failed++
  console.error(`FAIL: ${error instanceof Error ? error.message : String(error)}`)
}

// One HTTP request, no redirect followed: the checks want the sign-in's Set-Cookie and the room page's body.
function send(method, path, headers = {}, body) {
  return new Promise((resolve, reject) => {
    const request = http.request({ host, port, method, path, headers, agent: false }, (response) => {
      const chunks = []
      response.on("data", (chunk) => chunks.push(chunk))
      response.on("end", () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks).toString("utf8") }))
    })
    request.on("error", reject)
    if (body !== undefined) request.write(body)
    request.end()
  })
}

async function signIn() {
  const body = new URLSearchParams({ email_address: email, password }).toString()
  const response = await send("POST", "/session", {
    "content-type": "application/x-www-form-urlencoded",
    "sec-fetch-site": "same-origin",
    "user-agent": "campfire-cable-check",
  }, body)
  const cookie = (response.headers["set-cookie"] ?? []).map((value) => value.split(";")[0]).find((value) => value.startsWith("session_token="))
  if (!cookie) throw new Error(`sign-in answered HTTP ${response.status} without a session_token cookie`)
  return cookie
}

// The signed stream name the room page itself renders: the same Turbo verifier input the browser sends.
async function signedStreamName(cookie) {
  const response = await send("GET", "/rooms/1", { cookie, "user-agent": "campfire-cable-check" })
  if (response.status !== 200) throw new Error(`GET /rooms/1 answered HTTP ${response.status}, wanted the room page`)
  const match = /signed-stream-name="([^"]+)"/.exec(response.body)
  if (!match) throw new Error("the room page carries no turbo-cable-stream-source signed-stream-name")
  return match[1].replace(/&amp;/g, "&")
}

// The two Turbo room-list streams the sidebar fragment renders (Turbo::StreamsChannel): the shared "rooms"
// stream and the signed-in user's own list. The browser subscribes when the frame loads.
async function sidebarStreams(cookie) {
  const response = await send("GET", "/users/me/sidebar", { cookie, "user-agent": "campfire-cable-check" })
  if (response.status !== 200) throw new Error(`GET /users/me/sidebar answered HTTP ${response.status}, wanted the sidebar`)
  if (!/<turbo-frame[^>]*id="user_sidebar"/.test(response.body)) throw new Error("the sidebar fragment is not wrapped in turbo-frame#user_sidebar; the browser frame stays empty")
  const names = [...response.body.matchAll(/signed-stream-name="([^"]+)"/g)].map((match) => match[1].replace(/&amp;/g, "&"))
  if (names.length < 2) throw new Error(`the sidebar renders ${names.length} signed stream name(s), wanted Turbo's two`)
  return names
}

// A client WebSocket: the upgrade, masked text/close frames out, unmasked text/close/ping frames in.
class WebSocket {
  constructor(socket) {
    this.socket = socket
    this.buffer = Buffer.alloc(0)
    this.queue = []
    this.waiters = []
    this.closed = false
    this.failure = null
    socket.on("data", (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk])
      this.drain()
    })
    socket.on("close", () => this.stop(new Error("the server closed the socket")))
    socket.on("error", (error) => this.stop(error))
  }

  stop(error) {
    if (this.closed) return
    this.closed = true
    this.failure = error
    for (const waiter of this.waiters.splice(0)) {
      clearTimeout(waiter.timer)
      waiter.reject(error)
    }
  }

  drain() {
    try {
      for (;;) {
        const frame = this.frame()
        if (!frame) return
        if (frame.opcode === 0x1) this.deliver(frame.payload.toString("utf8"))
        else if (frame.opcode === 0x8) {
          this.stop(new Error("the server sent a close frame"))
          return
        } else if (frame.opcode === 0x9) this.write(0xa, frame.payload)
        // 0x0 continuation, 0xa pong and binary frames are not part of this protocol's traffic.
      }
    } catch (error) {
      this.stop(error)
    }
  }

  frame() {
    const bytes = this.buffer
    if (bytes.length < 2) return null
    const opcode = bytes[0] & 0x0f
    const masked = (bytes[1] & 0x80) !== 0
    let length = bytes[1] & 0x7f
    let at = 2
    if (length === 126) {
      if (bytes.length < at + 2) return null
      length = bytes.readUInt16BE(at)
      at += 2
    } else if (length === 127) {
      if (bytes.length < at + 8) return null
      const value = bytes.readBigUInt64BE(at)
      at += 8
      if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("a WebSocket frame is too large")
      length = Number(value)
    }
    let mask = null
    if (masked) {
      if (bytes.length < at + 4) return null
      mask = bytes.subarray(at, at + 4)
      at += 4
    }
    if (bytes.length < at + length) return null
    const payload = Buffer.from(bytes.subarray(at, at + length))
    if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4]
    this.buffer = bytes.subarray(at + length)
    return { opcode, payload }
  }

  write(opcode, payload) {
    if (this.closed) throw new Error("the socket is already closed")
    const length = payload.length
    let header
    if (length < 126) {
      header = Buffer.from([0x80 | opcode, 0x80 | length])
    } else if (length < 65536) {
      header = Buffer.alloc(4)
      header[0] = 0x80 | opcode
      header[1] = 0x80 | 126
      header.writeUInt16BE(length, 2)
    } else {
      header = Buffer.alloc(10)
      header[0] = 0x80 | opcode
      header[1] = 0x80 | 127
      header.writeBigUInt64BE(BigInt(length), 2)
    }
    const mask = crypto.randomBytes(4)
    const masked = Buffer.from(payload)
    for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i % 4]
    this.socket.write(Buffer.concat([header, mask, masked]))
  }

  sendText(text) {
    this.write(0x1, Buffer.from(text))
  }

  deliver(text) {
    const waiter = this.waiters.shift()
    if (!waiter) {
      this.queue.push(text)
      return
    }
    clearTimeout(waiter.timer)
    waiter.resolve(text)
  }

  next(timeout = 5000) {
    if (this.queue.length) return Promise.resolve(this.queue.shift())
    if (this.closed) return Promise.reject(this.failure ?? new Error("the socket is closed"))
    return new Promise((resolve, reject) => {
      const waiter = { resolve, reject, timer: null }
      waiter.timer = setTimeout(() => {
        const at = this.waiters.indexOf(waiter)
        if (at >= 0) this.waiters.splice(at, 1)
        reject(new Error(`no WebSocket frame within ${timeout} ms`))
      }, timeout)
      this.waiters.push(waiter)
    })
  }

  close() {
    if (this.closed) return
    try {
      this.write(0x8, Buffer.alloc(0))
    } catch {}
    this.stop(new Error("the check closed the socket"))
    this.socket.destroy()
  }
}

function open(cookie) {
  const headers = {
    Connection: "Upgrade",
    Upgrade: "websocket",
    "Sec-WebSocket-Key": crypto.randomBytes(16).toString("base64"),
    "Sec-WebSocket-Version": "13",
    "Sec-WebSocket-Protocol": PROTOCOL,
  }
  if (cookie) headers.Cookie = cookie
  return new Promise((resolve, reject) => {
    const request = http.request({ host, port, path: "/cable", method: "GET", headers, agent: false })
    request.on("upgrade", (response, socket, head) => {
      const selected = response.headers["sec-websocket-protocol"]
      if (selected !== PROTOCOL) {
        socket.destroy()
        reject(new Error(`the upgrade selected subprotocol ${JSON.stringify(selected)}, not ${PROTOCOL}`))
        return
      }
      const ws = new WebSocket(socket)
      if (head?.length) {
        ws.buffer = Buffer.concat([ws.buffer, head])
        ws.drain()
      }
      resolve(ws)
    })
    request.on("response", (response) => {
      response.resume()
      reject(new Error(`GET /cable did not upgrade: HTTP ${response.statusCode}`))
    })
    request.on("error", reject)
    request.end()
  })
}

async function waitFor(ws, type, timeout = 5000) {
  const deadline = Date.now() + timeout
  for (;;) {
    const left = deadline - Date.now()
    if (left <= 0) throw new Error(`no ${type} frame within ${timeout} ms`)
    const message = JSON.parse(await ws.next(left))
    if (message.type === type) return message
  }
}

function subscribe(ws, identifier) {
  const text = JSON.stringify(identifier)
  ws.sendText(JSON.stringify({ command: "subscribe", identifier: text }))
  return text
}

async function confirmed(ws, identifier, timeout = 5000) {
  const text = subscribe(ws, identifier)
  const deadline = Date.now() + timeout
  for (;;) {
    const left = deadline - Date.now()
    if (left <= 0) throw new Error(`no subscription answer for ${text} within ${timeout} ms`)
    const message = JSON.parse(await ws.next(left))
    if ((message.type === "confirm_subscription" || message.type === "reject_subscription") && message.identifier === text) return message.type
  }
}

let authenticated
try {
  const cookie = process.env.CABLE_COOKIE ?? (await signIn())
  const streamName = await signedStreamName(cookie)
  const turboStreams = await sidebarStreams(cookie)
  ok("the room page renders a Turbo signed stream name")

  authenticated = await open(cookie)
  const welcome = await waitFor(authenticated, "welcome", 3000)
  if (welcome.type === "welcome") ok("the socket opens with welcome")

  const channels = [
    { channel: "PresenceChannel", room_id: 1 },
    { channel: "TypingNotificationsChannel", room_id: 1 },
    { channel: "RoomMessagesChannel", signed_stream_name: streamName },
    { channel: "ReadRoomsChannel" },
    { channel: "HeartbeatChannel" },
    { channel: "UnreadRoomsChannel" },
    { channel: "Turbo::StreamsChannel", signed_stream_name: turboStreams[0] },
    { channel: "Turbo::StreamsChannel", signed_stream_name: turboStreams[1] },
  ]
  for (const identifier of channels) {
    const answer = await confirmed(authenticated, identifier)
    if (answer === "confirm_subscription") ok(`confirm_subscription for ${identifier.channel}`)
    else bad(`${identifier.channel} was rejected: ${answer}`)
  }

  const ping = await waitFor(authenticated, "ping", 4000)
  if (Number.isFinite(ping.message)) ok("a ping arrives within 4 s of the connection")
  else bad(`the ping carries no unix time: ${JSON.stringify(ping.message)}`)

  const unknown = await confirmed(authenticated, { channel: "NotADeclaredChannel" }, 3000)
  if (unknown === "reject_subscription") ok("an undeclared channel is rejected")
  else bad(`an undeclared channel was ${unknown}, wanted reject_subscription`)
} catch (error) {
  bad(error)
} finally {
  authenticated?.close()
}

let anonymous
try {
  anonymous = await open()
  const disconnect = await waitFor(anonymous, "disconnect", 3000)
  if (disconnect.reason === "unauthorized" && disconnect.reconnect === false) ok("a connection without a session cookie is told disconnect unauthorized")
  else bad(`the no-cookie disconnect was ${JSON.stringify(disconnect)}, wanted reason unauthorized and reconnect false`)
} catch (error) {
  bad(error)
} finally {
  anonymous?.close()
}

if (failed) {
  console.error(`FAIL: ${failed} Action Cable check(s) failed`)
  process.exit(1)
}
console.log("OK: the cable endpoint speaks actioncable-v1-json: welcome, ping, eight confirmations, a rejection, and the unauthorized disconnect")
process.exit(0)
