controller do

  layout_locals do
    signed_in = true
    user_id = current_user.id
    user_name = current_user.name
    logo_version = account_logo_version || ""
  end

  page_locals do
    base_url = request_base_url
    pwa_browser = pwa_browser(user_agent)
    pwa_os = pwa_os(user_agent)
    pwa_sc_ios = pwa_flag(user_agent, "sc_ios")
    pwa_ff_android = pwa_flag(user_agent, "ff_android")
    pwa_edge_desktop = pwa_flag(user_agent, "edge_desktop")
    pwa_ff_desktop = pwa_flag(user_agent, "ff_desktop")
    pwa_chrome_desktop = pwa_flag(user_agent, "chrome_desktop")
    pwa_chrome_android = pwa_flag(user_agent, "chrome_android")
    pwa_safari_desktop = pwa_flag(user_agent, "safari_desktop")
    pwa_ffchrome_desktop = pwa_flag(user_agent, "ffchrome_desktop")
    pwa_windows = pwa_flag(user_agent, "windows")
    pwa_install_hidden = pwa_flag(user_agent, "install_hidden")
    pwa_edge = pwa_flag(user_agent, "edge")
  end

  before :set_room, only: [:show], provides: :room

  def set_room
    room = room_for_user(id: params[:id], user_id: current_user.id)
    return redirect("/", alert: :room_not_found) if room.nil?
    room
  end

  # MessagesController#index: the newest 40 messages, and a strong ETag from the newest message id, so a
  # browser's If-None-Match is answered 304. The room is remembered in a plain last_room cookie, as Rails did
  # (`cookies.permanent[:last_room]`: not HttpOnly).
  #
  # The "Room not found or inaccessible" alert (RoomsController#set_room) goes with the redirect to /; / passes it on to
  # the room it redirects to (Rails keeps a flash nothing read), and a room page shows whatever flash it carries, once.
  def show
    flash = take_flash
    messages = last_page(room_id: room.id)
    newest = messages.last
    newest_id = newest.nil? ? 0 : newest.id
    etag("\"room-#{newest_id}\"")
    render_room(room, messages, flash.on, flash.alert, flash.text)
  end

  # The permalink: the page around one message (RoomsController#find_messages -> page_around), or the last page when
  # the message is not in this room.
  def show_at
    message_id = params[:message_id]
    room = room_for_user(id: params[:id], user_id: current_user.id)
    return redirect("/") if room.nil?
    around = messages_around(room_id: room.id, around: message_id)
    messages = around.empty? ? last_page(room_id: room.id) : around
    render_room(room, messages, false, false, "")
  end

  # The room page both `show` and `show_at` answer: the room's header, sidebar flags and stream, with the last_room cookie
  # remembered. The flash is the caller's: `show` takes it, `show_at` leaves the cookie as it came.
  def render_room(room, messages, flash_on, flash_alert, flash_text)
    page = room_page(id: params[:id], user_id: current_user.id) || raise("the room page was not read back")
    flags = current_flags
    set_cookie :last_room, room.id.to_s, signed: false, http_only: false
    body_class = "sidebar#{flags.admin == 1 ? " admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    direct = page.kind == "direct"
    room_class = page.kind == "open" ? "Rooms::Open" : (page.kind == "closed" ? "Rooms::Closed" : "Rooms::Direct")
    stream_name = turbo_signed_stream_name(global_id_param(room_class, room.id, app: "campfire"), :messages, secret: :secret_key)
    invitation = page.is_original == 1 && page.message_count <= 40
    join_url = invitation ? "#{request_base_url}/join/#{account_join_code || ""}" : ""
    qr_id = invitation ? urlsafe_base64(join_url) : ""
    render :room_show, locals: { noun: direct ? "Ping" : "room", kind: page.kind, plural: "#{page.kind}s", has_logo: flags.logo == 1, updated_ms: page.updated_ms.to_s, user_title: flags.title, user_version: flags.version, can_administer: flags.admin == 1, title: page.label, room_id: room.id, room_name: room.name, flash_on: flash_on, flash_alert: flash_alert, flash_text: flash_text }
  end

  def messages_page
    room = room_for_user(id: params[:id], user_id: current_user.id)
    return redirect("/") if room.nil?
    before = params[:before]
    after = params[:after]
    older = before.nil? ? last_page(room_id: room.id) : messages_before(room_id: room.id, before: before)
    page = after.nil? ? older : messages_after(room_id: room.id, after: after)
    return halt(204, "") if page.empty?
    render :messages_page, layout: nil, locals: { messages: page, base_url: request_base_url }
  end

  # MessagesController#create: a member writes to the room, and the answer is the Turbo Stream that appends the
  # message. The message, its Action Text body and its FTS row are one transaction: a failure between the inserts
  # rolls all three back, leaving no partial message (GAPS.md 13).
  def post_message
    # Neither `message[body]` nor `message[attachment]` is a post of no message at all (Rails' `params.require(:message)`
    # fails); the body is optional only because the composer's file post has none.
    attachment = params[:attachment]
    body_param = params[:body]
    return halt(422, "") if body_param.nil? && attachment.nil?
    room = room_class_for_user(id: params[:id], user_id: current_user.id)
    # MessagesController#create: set_room raises RecordNotFound for a room the user is not in (or that was deleted), and
    # `rescue ActiveRecord::RecordNotFound` renders messages/room_not_found (200, the application layout) for the composer frame. MessagesController.s
    # `layout false, only: :index` keeps the application layout for a Turbo-Frame request too (`frame_layout: false`).
    return render(:room_not_found, frame_layout: false, locals: { title: "Campfire", body_class: current_flags.admin == 1 ? "admin" : "" }) if room.nil?
    client_message_id = params[:client_message_id] || ""
    body = body_param || ""
    # Message#plain_text_body: `body.to_plain_text.presence || attachment&.filename`, what Message::Searchable indexes.
    body_text = plain_text(body)
    indexed = body_text.strip.empty? ? (attachment&.filename || "") : body_text
    # Message::Attachment and Message#process_attachment (models/message.axum.rb, create_room_message): the file, the
    # message's rows in one transaction, and an image's :thumb variant.
    message_id = create_room_message(room.id, current_user.id, client_message_id, body, indexed, attachment)
    message = message_row(id: message_id) || raise("the new message was not read back")
    # set_room already holds the STI class; the stream target needs only its short kind. Reading the whole
    # room_page here would count messages and resolve a direct room's display label for no reason.
    kind = room.class_name == "Rooms::Open" ? "open" : (room.class_name == "Rooms::Closed" ? "closed" : "direct")
    # Message::Broadcasts#broadcast_create (called by MessagesController#create before it answers): append the message to the
    # room's messages stream, rendered without a request, then tell every member's UnreadRoomsChannel stream, the sender
    # included. The partial's absolute URLs (the copy link) come from SetCurrentRequest's default_url_options, which carry
    # only the request's protocol and host: the port never shows (http://localhost:3999 broadcasts http://localhost/...).
    origin = request_base_url.split(":")
    broadcast_base = "#{origin[0] || ""}:#{origin[1] || ""}"
    broadcast_append_to(room, :messages, app: "campfire", target: "messages_rooms_#{kind}_#{room.id}", html: render_string(:message_broadcast, from: message, locals: { message_id: message.id, base_url: broadcast_base }))
    room_member_ids(room_id: room.id).each { |member| broadcast("user_#{member.user_id}_unreads", "roomId" => room.id) }
    # Room#receive's push_later (Room::PushMessageJob, then WebPush::Pool's threads): after the answer, each recipient's
    # notification -- the creator for a ping, else the room and the creator -- and the subscriptions the push service
    # or the key refuses go (the pool's invalid-subscription handler).
    push_title = kind == "direct" ? message.creator_name : message.room_label
    push_body = kind == "direct" ? indexed : "#{message.creator_name}: #{indexed}"
    stored_body = body
    room_name = kind == "direct" ? nil : message.room_label # Rails' message.room.name: nil for a ping
    later do
      push_targets(room_id: room.id, creator_id: current_user.id, body: stored_body).each do |target|
        refused = web_push(target.endpoint, target.p256dh, target.auth,
                           json_object("title" => push_title, "options" => json_object("body" => push_body, "icon" => "/account/logo", "data" => json_object("path" => "/rooms/#{room.id}", "badge" => target.badge))),
                           setting(:vapid_public_key), setting(:vapid_private_key), "mailto:support@37signals.com")
        if refused == 1
          delete_push_subscription_by_id(id: target.id)
        end
      end
      # MessagesController#deliver_webhooks_to_bots (Bot::WebhookJob, Webhook#deliver): each bot's payload, and the reply
      # its webhook answers posted back to the room by the bot (receive_text_reply_to: created, broadcast and received).
      # The job renders the reply's broadcast with ApplicationController.renderer's defaults: http://example.org.
      webhook_bots(room_id: room.id, creator_id: current_user.id, body: stored_body, direct: kind == "direct" ? 1 : 0).each do |bot|
        plain = Rust.Str(indexed).replace("@#{bot.name}", "").to_s.strip # without_recipient_mentions
        reply = webhook_post(bot.url, json_object("user" => json_object("id" => current_user.id, "name" => current_user.name),
                                                  "room" => json_object("id" => room.id, "name" => room_name, "path" => "/rooms/#{room.id}/#{bot.bot_key}/messages"),
                                                  "message" => json_object("id" => message.id, "body" => json_object("html" => stored_body, "plain" => plain), "path" => "/rooms/#{room.id}/@#{message.id}")))
        has_reply = !reply.nil?
        reply_text = action_text_html(reply || "") # receive_text_reply_to's body, as Action Text stores it
        reply_plain = plain_text(reply_text)
        reply_uuid = random_uuid
        if has_reply
          reply_id = create_text_message(room.id, bot.id, reply_uuid, reply_text, reply_plain)
          posted = message_row(id: reply_id) || raise("the webhook reply was not read back")
          broadcast_append_to(room, :messages, app: "campfire", target: "messages_rooms_#{kind}_#{room.id}", html: render_string(:message_broadcast, from: posted, locals: { message_id: posted.id, base_url: "http://example.org" }))
          room_member_ids(room_id: room.id).each { |member| broadcast("user_#{member.user_id}_unreads", "roomId" => room.id) }
          push_targets(room_id: room.id, creator_id: bot.id, body: reply_text).each do |target|
            refused_reply = web_push(target.endpoint, target.p256dh, target.auth,
                                     json_object("title" => kind == "direct" ? posted.creator_name : posted.room_label, "options" => json_object("body" => kind == "direct" ? reply_plain : "#{posted.creator_name}: #{reply_plain}", "icon" => "/account/logo", "data" => json_object("path" => "/rooms/#{room.id}", "badge" => target.badge))),
                                     setting(:vapid_public_key), setting(:vapid_private_key), "mailto:support@37signals.com")
            if refused_reply == 1
              delete_push_subscription_by_id(id: target.id)
            end
          end
        end
      end
    end
    render :message_stream, layout: nil, content_type: "text/vnd.turbo-stream.html; charset=utf-8", from: message, locals: { kind: kind, base_url: request_base_url, message_id: message.id, body: message.body }
  end
end
