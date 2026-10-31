// The Action Cable broadcasts of Campfire (campfire.axum.rb's `cable "/cable"` plus the routes that broadcast), driven
// over real WebSockets with node alone, against the service test/e2e_campfire.sh already started on its seeded
// database. David (an administrator) and Jason are both in room 1 (Watercooler, Rooms::Open) and subscribe the way the
// browser does; David then acts over HTTP, and each frame the other subscriber and David himself receive is compared
// with the frame once-campfire writes (Turbo::StreamsChannel.broadcast_*_to and ActionCable.server.broadcast, whose JSON is
// escaped as ActiveSupport escapes it: < > & as < > &):
//
//   message post   RoomMessagesChannel: a turbo-stream append of the message to messages_rooms_open_1, then (a second
//                  subscription) UnreadRoomsChannel: {"roomId":1} for every member, the poster included
//   boost          RoomMessagesChannel: append to boosts_message_<client_message_id>, maintain_scroll="true"; then remove boost_<id>
//   edit           RoomMessagesChannel: replace presentation_message_<client_message_id>, maintain_scroll="true"
//   delete         RoomMessagesChannel: remove message_<client_message_id>
//   typing         TypingNotificationsChannel: {"action":"start","user":{"id":1,"name":"David Heinemeier"}} to everyone in the room
//   presence       ReadRoomsChannel: {"room_id":1} when the same user's PresenceChannel subscription is confirmed
//
// The message and boost markup is a rendered partial, so its exact bytes are not repeated here: the check pins the
// tag around it byte for byte and the markers inside (ids, the body, the copy-link host without the port, no CSRF field).
// CABLE_COOKIE is David's session_token cookie and CABLE_COOKIE_JASON Jason's (test/e2e_campfire.sh passes both).
// usage: node test/cable_broadcast_check.mjs [BASE_URL]      (default http://127.0.0.1:8099)
import crypto from "node:crypto"
import http from "node:http"

const base = process.argv[2] ?? process.env.CABLE_BASE ?? "http://127.0.0.1:8099"
const origin = new URL(base)
const host = origin.hostname
const port = Number(origin.port || 80)
const PROTOCOL = "actioncable-v1-json"
const davidCookie = process.env.CABLE_COOKIE
const jasonCookie = process.env.CABLE_COOKIE_JASON
if (!davidCookie || !jasonCookie) {
  console.error("FAIL: set CABLE_COOKIE (david) and CABLE_COOKIE_JASON (jason) to their session_token cookies")
  process.exit(1)
}

let failed = 0
const ok = (text) => console.log(`ok: ${text}`)
const bad = (error) => {
  failed++
  console.error(`FAIL: ${error instanceof Error ? error.message : String(error)}`)
}

// One HTTP request, no redirect followed. A form body is URL-encoded; a write carries Fetch Metadata like a browser's.
function send(method, path, cookie, form) {
  const body = form === undefined ? undefined : new URLSearchParams(form).toString()
  const headers = { cookie, "user-agent": "campfire-cable-broadcast-check", "sec-fetch-site": "same-origin" }
  if (body !== undefined) headers["content-type"] = "application/x-www-form-urlencoded"
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

// A multipart/form-data POST (the composer's XHR sends one for a file): text fields, then one file part.
function sendMultipart(path, cookie, fields, file) {
  const boundary = `----cablecheck${crypto.randomBytes(8).toString("hex")}`
  const parts = []
  for (const [name, value] of Object.entries(fields)) {
    parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`))
  }
  parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${file.name}"; filename="${file.filename}"\r\nContent-Type: ${file.type}\r\n\r\n`))
  parts.push(Buffer.from(file.bytes))
  parts.push(Buffer.from(`\r\n--${boundary}--\r\n`))
  const body = Buffer.concat(parts)
  const headers = { cookie, "user-agent": "campfire-cable-broadcast-check", "sec-fetch-site": "same-origin", "content-type": `multipart/form-data; boundary=${boundary}`, "content-length": body.length }
  return new Promise((resolve, reject) => {
    const request = http.request({ host, port, method: "POST", path, headers, agent: false }, (response) => {
      const chunks = []
      response.on("data", (chunk) => chunks.push(chunk))
      response.on("end", () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks).toString("utf8") }))
    })
    request.on("error", reject)
    request.end(body)
  })
}

async function roomStreamName() {
  const response = await send("GET", "/rooms/1", davidCookie)
  if (response.status !== 200) throw new Error(`GET /rooms/1 answered HTTP ${response.status}, wanted the room page`)
  const match = /signed-stream-name="([^"]+)"/.exec(response.body)
  if (!match) throw new Error("the room page carries no turbo-cable-stream-source signed-stream-name")
  return match[1].replace(/&amp;/g, "&")
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


// A frame the way ActiveSupport writes it: <, > and & become <, > and &.
const escapeHtml = (json) => json.replaceAll("<", "\\u003c").replaceAll(">", "\\u003e").replaceAll("&", "\\u0026")
const frame = (identifier, messageJson) => escapeHtml(`{"identifier":${JSON.stringify(identifier)},"message":${messageJson}}`)

// The next frame that is not the 3 second ping.
async function nextFrame(ws, timeout = 5000) {
  const deadline = Date.now() + timeout
  for (;;) {
    const left = deadline - Date.now()
    if (left <= 0) throw new Error(`no frame within ${timeout} ms`)
    const text = await ws.next(left)
    if (!text.startsWith('{"type":"ping"')) return text
  }
}

async function expectFrame(label, ws, expected) {
  try {
    const got = await nextFrame(ws)
    if (got === expected) ok(label)
    else bad(`${label}\n      wanted ${expected}\n      got    ${got}`)
  } catch (error) {
    bad(`${label}: ${error.message}`)
  }
}

// The next frame, parsed: its identifier is the one asked for and its message is a string (a Turbo Stream tag).
async function nextTurbo(label, ws, identifier) {
  try {
    const text = await nextFrame(ws)
    const parsed = JSON.parse(text)
    if (parsed.identifier !== identifier) throw new Error(`the identifier is ${parsed.identifier}, wanted ${identifier}`)
    if (typeof parsed.message !== "string") throw new Error(`the message is not a Turbo Stream string: ${text}`)
    if (/[<>&]/.test(text)) throw new Error("the frame text holds a raw <, > or &; ActiveSupport writes them as \\u003c, \\u003e and \\u0026")
    return parsed.message
  } catch (error) {
    bad(`${label}: ${error.message}`)
    return ""
  }
}

function expectTag(label, html, prefix, suffix, markers = [], absent = []) {
  const problems = []
  if (!html.startsWith(prefix)) problems.push(`does not start with ${prefix}`)
  if (!html.endsWith(suffix)) problems.push(`does not end with ${suffix}`)
  for (const marker of markers) if (!html.includes(marker)) problems.push(`lacks ${marker}`)
  for (const marker of absent) if (html.includes(marker)) problems.push(`holds ${marker}`)
  if (problems.length === 0) ok(label)
  else bad(`${label}: ${problems.join("; ")}\n      got ${html.slice(0, 400)}`)
}

async function subscribed(ws, fields) {
  const text = JSON.stringify(fields)
  ws.sendText(JSON.stringify({ command: "subscribe", identifier: text }))
  const got = await nextFrame(ws)
  const want = `{"identifier":${JSON.stringify(text)},"type":"confirm_subscription"}`
  if (got !== want) throw new Error(`${fields.channel}: wanted ${want}, got ${got}`)
  return text
}

const sockets = []
try {
  const streamName = await roomStreamName()
  const david = await open(davidCookie)
  const jason = await open(jasonCookie)
  sockets.push(david, jason)
  for (const ws of [david, jason]) {
    const first = await nextFrame(ws, 3000)
    if (first !== '{"type":"welcome"}') throw new Error(`the first frame is ${first}, wanted welcome`)
  }
  ok("david and jason are connected")

  // The browser's subscriptions for a room page, minus Presence (it would broadcast a read before the checks begin).
  const messages = { channel: "RoomMessagesChannel", signed_stream_name: streamName }
  const unread = { channel: "UnreadRoomsChannel" }
  const typing = { channel: "TypingNotificationsChannel", room_id: 1 }
  const ids = {}
  for (const [name, ws] of [["david", david], ["jason", jason]]) {
    ids[name] = {
      messages: await subscribed(ws, messages),
      unread: await subscribed(ws, unread),
      typing: await subscribed(ws, typing),
    }
  }
  ids.david.reads = await subscribed(david, { channel: "ReadRoomsChannel" })
  ok("both subscribe to RoomMessagesChannel, UnreadRoomsChannel and TypingNotificationsChannel; david also to ReadRoomsChannel")

  // --- MessagesController#create: Message::Broadcasts#broadcast_create -------------------------------------------
  const posted = await send("POST", "/rooms/1/messages", davidCookie, { "message[body]": "Cable check says hello", "message[client_message_id]": "cable-1" })
  if (posted.status !== 200) bad(`POST /rooms/1/messages answered HTTP ${posted.status}`)
  let messageId = ""
  for (const [name, ws] of [["jason", jason], ["david", david]]) {
    const html = await nextTurbo(`${name} receives the appended message`, ws, ids[name].messages)
    messageId = /data-message-id="(\d+)"/.exec(html)?.[1] ?? messageId
    expectTag(`the append to ${name} is the Turbo tag Rails writes around the message`, html,
      '<turbo-stream action="append" target="messages_rooms_open_1"><template>', "</template></turbo-stream>",
      ['id="message_cable-1"', 'id="edit_message_cable-1"', "Cable check says hello", 'data-user-id="1"', `http://${host}/rooms/1/@`],
      ["authenticity_token", "csrf"])
    await expectFrame(`${name} then receives the unread ping, as Rails sends it to every member`, ws, frame(ids[name].unread, '{"roomId":1}'))
  }
  if (!messageId) throw new Error("the appended message carries no data-message-id")

  // --- Messages::BoostsController#create / #destroy ---------------------------------------------------------------
  await send("POST", `/messages/${messageId}/boosts`, davidCookie, { "boost[content]": "Great!" })
  let boostId = ""
  for (const [name, ws] of [["jason", jason], ["david", david]]) {
    const html = await nextTurbo(`${name} receives the boost`, ws, ids[name].messages)
    boostId = /id="boost_(\d+)"/.exec(html)?.[1] ?? boostId
    expectTag(`the boost append to ${name} targets the message's boosts and keeps the scroll`, html,
      '<turbo-stream maintain_scroll="true" action="append" target="boosts_message_cable-1"><template>', "</template></turbo-stream>",
      ['data-boost-delete-booster-id-value="1"', "David Heinemeier boosted Great!", `action="/messages/${messageId}/boosts/`, 'id="delete_boost_accessible_label"'],
      ["authenticity_token"])
  }
  if (!boostId) throw new Error("the appended boost carries no id")
  await send("POST", `/messages/${messageId}/boosts/${boostId}`, davidCookie, { _method: "delete" })
  for (const [name, ws] of [["jason", jason], ["david", david]]) {
    await expectFrame(`${name} receives the boost removal`, ws, frame(ids[name].messages, JSON.stringify(`<turbo-stream action="remove" target="boost_${boostId}"></turbo-stream>`)))
  }

  // --- MessagesController#update: broadcast_replace_to @room, :messages, target: [ @message, :presentation ] ------------
  await send("POST", `/rooms/1/messages/${messageId}`, davidCookie, { _method: "patch", "message[body]": "Cable check says goodbye" })
  for (const [name, ws] of [["jason", jason], ["david", david]]) {
    const html = await nextTurbo(`${name} receives the edited presentation`, ws, ids[name].messages)
    expectTag(`the replace to ${name} swaps the presentation div and keeps the scroll`, html,
      '<turbo-stream maintain_scroll="true" action="replace" target="presentation_message_cable-1"><template><div id="presentation_message_cable-1" dir="auto" data-reply-target="body" data-messages-target="body">',
      // messages/_presentation.html.erb ends with "</div>" and its newline (a text line, which ERB does not trim), and
      // turbo_stream_action_tag wraps the rendered partial as is.
      "</div>\n</template></turbo-stream>", ["Cable check says goodbye"], ["Cable check says hello", "authenticity_token"])
  }

  // --- TypingNotificationsChannel#start / #stop -------------------------------------------------------------------
  david.sendText(JSON.stringify({ command: "message", identifier: ids.david.typing, data: JSON.stringify({ action: "start" }) }))
  for (const [name, ws] of [["jason", jason], ["david", david]]) {
    await expectFrame(`${name} sees david typing: broadcast_to @room, action: :start, user: slice(:id, :name)`, ws, frame(ids[name].typing, '{"action":"start","user":{"id":1,"name":"David Heinemeier"}}'))
  }
  david.sendText(JSON.stringify({ command: "message", identifier: ids.david.typing, data: JSON.stringify({ action: "stop" }) }))
  for (const [name, ws] of [["jason", jason], ["david", david]]) {
    await expectFrame(`${name} sees david stop`, ws, frame(ids[name].typing, '{"action":"stop","user":{"id":1,"name":"David Heinemeier"}}'))
  }

  // --- MessagesController#destroy: Message::Broadcasts#broadcast_remove ------------------------------------------------
  await send("POST", `/rooms/1/messages/${messageId}`, davidCookie, { _method: "delete" })
  for (const [name, ws] of [["jason", jason], ["david", david]]) {
    await expectFrame(`${name} receives the message removal`, ws, frame(ids[name].messages, JSON.stringify('<turbo-stream action="remove" target="message_cable-1"></turbo-stream>')))
  }

  // --- MessagesController#create with `message[attachment]` and no body: the same broadcast_create (UNRUN until the owner saves) ---
  // The composer's file post is multipart with message[attachment] and message[client_message_id]. The appended message
  // draws the attachment (messages/_presentation: the lightbox link around the image with class message__attachment, whose
  // src is the :thumb representation URL) and the sender's UnreadRoomsChannel ping follows, as for a text message.
  const attached = await sendMultipart("/rooms/1/messages", davidCookie, { "message[client_message_id]": "cable-att" },
    { name: "message[attachment]", filename: "moon.jpg", type: "image/jpeg", bytes: "cable attachment bytes" })
  if (attached.status !== 200) bad(`POST /rooms/1/messages with an attachment answered HTTP ${attached.status}`)
  for (const [name, ws] of [["jason", jason], ["david", david]]) {
    const html = await nextTurbo(`${name} receives the appended attachment message`, ws, ids[name].messages)
    expectTag(`the attachment append to ${name} is the Turbo tag Rails writes around the message`, html,
      '<turbo-stream action="append" target="messages_rooms_open_1"><template>', "</template></turbo-stream>",
      ['id="message_cable-att"', "message__attachment", "/rails/active_storage/representations/redirect/", "/moon.jpg", "/rails/active_storage/blobs/redirect/", 'data-user-id="1"'],
      ["authenticity_token", "csrf"])
    await expectFrame(`${name} then receives the unread ping`, ws, frame(ids[name].unread, '{"roomId":1}'))
  }
  const attachedId = /data-message-id="(\d+)"/.exec(attached.body)?.[1]
  await send("POST", `/rooms/1/messages/${attachedId}`, davidCookie, { _method: "delete" })
  for (const [name, ws] of [["jason", jason], ["david", david]]) {
    await expectFrame(`${name} receives the attachment message's removal`, ws, frame(ids[name].messages, JSON.stringify('<turbo-stream action="remove" target="message_cable-att"></turbo-stream>')))
  }

  // --- Rooms::OpensController#create / RoomsController#destroy: broadcast_prepend_to / broadcast_remove_to :rooms ---------
  // Unrun until the owner saves the tree. Jason's sidebar subscribes to Turbo::StreamsChannel on the signed "rooms" stream
  // (the first turbo-cable-stream-source of /users/me/sidebar).
  const sidebar = await send("GET", "/users/me/sidebar", jasonCookie)
  const roomsStream = /signed-stream-name="([^"]+)"/.exec(sidebar.body)?.[1]?.replace(/&amp;/g, "&")
  if (!roomsStream) throw new Error("the sidebar carries no signed stream name for :rooms")
  const roomsId = await subscribed(jason, { channel: "Turbo::StreamsChannel", signed_stream_name: roomsStream })
  const created = await send("POST", "/rooms/opens", davidCookie, { "room[name]": "Cable room" })
  const newRoomId = /\/rooms\/(\d+)$/.exec(created.headers.location ?? "")?.[1]
  if (created.status !== 302 || !newRoomId) throw new Error(`POST /rooms/opens answered HTTP ${created.status}, Location ${created.headers.location}`)
  const prepended = await nextTurbo("jason receives the new room in shared_rooms", jason, roomsId)
  expectTag("the prepend puts the room link in shared_rooms", prepended, '<turbo-stream action="prepend" target="shared_rooms"><template>',
    "</template></turbo-stream>", [`id="list_rooms_open_${newRoomId}"`, `data-room-id="${newRoomId}"`, `href="/rooms/${newRoomId}"`, "Cable room"], ["authenticity_token"])
  // --- Rooms::ClosedsController#update: broadcast_update_room (UNRUN until the owner saves) -----------------------------------
  // The open room becomes closed (force_room_type), is renamed and revised to david and jason; every member that remains has
  // the room's sidebar entry replaced on their own User#<id>:rooms stream (the sidebar's second signed stream). Rita, whom the
  // open room had granted, is revoked and gets no frame (Rails closes her cable connections instead).
  const userStream = [...sidebar.body.matchAll(/signed-stream-name="([^"]+)"/g)].map((m) => m[1].replace(/&amp;/g, "&"))[1]
  if (!userStream) throw new Error("the sidebar carries no second signed stream name for the user's :rooms")
  const userRoomsId = await subscribed(jason, { channel: "Turbo::StreamsChannel", signed_stream_name: userStream })
  const revised = await send("POST", `/rooms/closeds/${newRoomId}`, davidCookie,
    [["_method", "patch"], ["room[name]", "Cable closed"], ["user_ids[]", "1"], ["user_ids[]", "2"]])
  if (revised.status !== 302) bad(`PATCH /rooms/closeds/${newRoomId} answered HTTP ${revised.status}`)
  const replaced = await nextTurbo("jason receives the closed room's replaced sidebar entry", jason, userRoomsId)
  expectTag("the replace swaps the room link in place", replaced, `<turbo-stream action="replace" target="list_rooms_closed_${newRoomId}"><template>`,
    "</template></turbo-stream>", [`id="list_rooms_closed_${newRoomId}"`, `data-room-id="${newRoomId}"`, "Cable closed"], ["authenticity_token"])
  await send("POST", `/rooms/${newRoomId}`, davidCookie, { _method: "delete" })
  await expectFrame("jason receives the room's removal", jason, frame(roomsId, JSON.stringify(`<turbo-stream action="remove" target="list_rooms_closed_${newRoomId}"></turbo-stream>`)))

  // --- PresenceChannel#present: broadcast_read_room ---------------------------------------------------------------------
  await subscribed(david, { channel: "PresenceChannel", room_id: 1 })
  await expectFrame("david's confirmed PresenceChannel subscription tells his ReadRoomsChannel", david, frame(ids.david.reads, '{"room_id":1}'))
} catch (error) {
  bad(error)
} finally {
  for (const ws of sockets) ws.close()
}

if (failed) {
  console.error(`FAIL: ${failed} Campfire cable broadcast check(s) failed`)
  process.exit(1)
}
console.log("OK: the Campfire cable broadcasts match the frames Rails sends: message append and unread ping, boost append and remove, edit replace, typing, message remove, presence read")
process.exit(0)
