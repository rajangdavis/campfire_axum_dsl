fragment do
  # MessagesController#index: the newest 40 messages, and a strong ETag from the newest message id, so a
  # browser's If-None-Match is answered 304. The room is remembered in a plain last_room cookie, as Rails did
  # (`cookies.permanent[:last_room]`: not HttpOnly).
  #
  # The "Room not found or inaccessible" alert (RoomsController#set_room) travels in the _campfire_session cookie's value as
  # a ".room_not_found" suffix on the session token: this route writes it before redirecting to /, / leaves the cookie
  # alone (the :rack_defaults layer sends the value it carried), and this route shows it once and writes the token back.
  get "/rooms/:id", params: :RoomPath, cache: :private, description: "A room: its newest 40 messages, oldest first" do
    user = current(:user)
    room = room_for_user(id: params[:id], user_id: user.id)
    session = cookie(:_campfire_session, signed: false).to_s
    flash = session.end_with?(".room_not_found")
    token = flash ? session[0, session.length - 15].to_s : session
    # An empty token (no cookie came) is dropped by :rack_defaults, which then writes a fresh session cookie.
    set_cookie :_campfire_session, room.nil? ? "#{token}.room_not_found" : token, signed: false
    return redirect("/") if room.nil?
    page = room_page(id: params[:id], user_id: user.id) || raise("the room page was not read back")
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    messages = last_page(room_id: room.id)
    newest = messages.last
    newest_id = newest.nil? ? 0 : newest.id
    etag("\"room-#{newest_id}\"")
    set_cookie :last_room, room.id.to_s, signed: false, http_only: false
    body_class = "sidebar#{flags.admin == 1 ? " admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    direct = page.kind == "direct"
    room_class = page.kind == "open" ? "Rooms::Open" : (page.kind == "closed" ? "Rooms::Closed" : "Rooms::Direct")
    stream_name = turbo_signed_stream_name(global_id_param(room_class, room.id, app: "campfire"), :messages, secret: :secret_key)
    invitation = page.is_original == 1 && page.message_count <= 40
    join_url = invitation ? "#{request_base_url}/join/#{account_join_code || ""}" : ""
    qr_id = invitation ? urlsafe_base64(join_url) : ""
    render :room_show, locals: { body_class: body_class, direct: direct, noun: direct ? "Ping" : "room", kind: page.kind, plural: "#{page.kind}s", base_url: request_base_url, has_logo: flags.logo == 1, updated_ms: page.updated_ms.to_s, user_title: flags.title, user_version: flags.version, stream_name: stream_name, invitation: invitation, join_url: join_url, qr_id: qr_id, can_administer: flags.admin == 1, title: page.label, logo_version: account_logo_version || "", vapid_key: setting(:vapid_public_key), room_id: room.id, room_name: room.name, messages: messages, signed_in: true, user_id: user.id, user_name: user.name, flash_on: flash, flash_alert: flash, flash_text: flash ? "Room not found or inaccessible" : "", pwa_browser: pwa_browser(user_agent), pwa_os: pwa_os(user_agent), pwa_sc_ios: pwa_flag(user_agent, "sc_ios"), pwa_ff_android: pwa_flag(user_agent, "ff_android"), pwa_edge_desktop: pwa_flag(user_agent, "edge_desktop"), pwa_ff_desktop: pwa_flag(user_agent, "ff_desktop"), pwa_chrome_desktop: pwa_flag(user_agent, "chrome_desktop"), pwa_chrome_android: pwa_flag(user_agent, "chrome_android"), pwa_safari_desktop: pwa_flag(user_agent, "safari_desktop"), pwa_ffchrome_desktop: pwa_flag(user_agent, "ffchrome_desktop"), pwa_windows: pwa_flag(user_agent, "windows"), pwa_install_hidden: pwa_flag(user_agent, "install_hidden"), pwa_edge: pwa_flag(user_agent, "edge") }
  end

  # The permalink: the page around one message (RoomsController#find_messages -> page_around), or the last page when
  # the message is not in this room.
  get "/rooms/:id/@:message_id", params: :RoomAtPath, cache: :private, description: "A room opened at one message: the 40 before it, it, the 40 after" do
    message_id = params[:message_id]
    user = current(:user)
    room = room_for_user(id: params[:id], user_id: user.id)
    return redirect("/") if room.nil?
    page = room_page(id: params[:id], user_id: user.id) || raise("the room page was not read back")
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    around = messages_around(room_id: room.id, around: message_id)
    messages = around.empty? ? last_page(room_id: room.id) : around
    set_cookie :last_room, room.id.to_s, signed: false, http_only: false
    body_class = "sidebar#{flags.admin == 1 ? " admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    direct = page.kind == "direct"
    room_class = page.kind == "open" ? "Rooms::Open" : (page.kind == "closed" ? "Rooms::Closed" : "Rooms::Direct")
    stream_name = turbo_signed_stream_name(global_id_param(room_class, room.id, app: "campfire"), :messages, secret: :secret_key)
    invitation = page.is_original == 1 && page.message_count <= 40
    join_url = invitation ? "#{request_base_url}/join/#{account_join_code || ""}" : ""
    qr_id = invitation ? urlsafe_base64(join_url) : ""
    render :room_show, locals: { body_class: body_class, direct: direct, noun: direct ? "Ping" : "room", kind: page.kind, plural: "#{page.kind}s", base_url: request_base_url, has_logo: flags.logo == 1, updated_ms: page.updated_ms.to_s, user_title: flags.title, user_version: flags.version, stream_name: stream_name, invitation: invitation, join_url: join_url, qr_id: qr_id, can_administer: flags.admin == 1, title: page.label, logo_version: account_logo_version || "", vapid_key: setting(:vapid_public_key), room_id: room.id, room_name: room.name, messages: messages, signed_in: true, user_id: user.id, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "", pwa_browser: pwa_browser(user_agent), pwa_os: pwa_os(user_agent), pwa_sc_ios: pwa_flag(user_agent, "sc_ios"), pwa_ff_android: pwa_flag(user_agent, "ff_android"), pwa_edge_desktop: pwa_flag(user_agent, "edge_desktop"), pwa_ff_desktop: pwa_flag(user_agent, "ff_desktop"), pwa_chrome_desktop: pwa_flag(user_agent, "chrome_desktop"), pwa_chrome_android: pwa_flag(user_agent, "chrome_android"), pwa_safari_desktop: pwa_flag(user_agent, "safari_desktop"), pwa_ffchrome_desktop: pwa_flag(user_agent, "ffchrome_desktop"), pwa_windows: pwa_flag(user_agent, "windows"), pwa_install_hidden: pwa_flag(user_agent, "install_hidden"), pwa_edge: pwa_flag(user_agent, "edge") }
  end

  get "/rooms/:id/messages", params: :PageParams, cache: :private, description: "The 40 messages before one, as a fragment (204 when there are none)" do
    user = current(:user)
    room = room_for_user(id: params[:id], user_id: user.id)
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
  post "/rooms/:id/messages", params: :NewMessage, description: "Post a message to the room and stream it back" do
    user = current(:user)
    # Neither `message[body]` nor `message[attachment]` is a post of no message at all (Rails' `params.require(:message)`
    # fails); the body is optional only because the composer's file post has none.
    attachment = params[:attachment]
    body_param = params[:body]
    return halt(422, "") if body_param.nil? && attachment.nil?
    room = room_class_for_user(id: params[:id], user_id: user.id)
    # MessagesController#create: set_room raises RecordNotFound for a room the user is not in (or that was deleted), and
    # `rescue ActiveRecord::RecordNotFound` renders messages/room_not_found (200, the application layout) for the composer frame.
    missing_flags = room.nil? ? body_flags(user_id: user.id) : nil
    return render(:room_not_found, locals: { title: "Campfire", body_class: missing_flags.nil? ? "" : (missing_flags.admin == 1 ? "admin" : ""), vapid_key: setting(:vapid_public_key), logo_version: account_logo_version || "", signed_in: true, user_id: user.id, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "" }) if room.nil?
    client_message_id = params[:client_message_id] || ""
    body = body_param || ""
    # Message::Attachment (has_one_attached :attachment): the composer's file post carries `message[attachment]` and no
    # body. The file is written to Active Storage's Disk service first (a failed write answers 500 before any row exists);
    # the blob and attachment rows go in the message's transaction and do nothing without a file. No width, height or
    # :thumb variant is made (the DSL cannot read an image), so the new message's representation has no variant yet.
    file_name = attachment&.filename || ""
    # Message#plain_text_body: the body's text, else the attachment's filename (what Message::Searchable indexes).
    indexed = body.empty? ? file_name : body
    file_type = attachment&.content_type || ""
    file_size = attachment&.size || 0
    file_checksum = attachment&.checksum || ""
    file_metadata = attachment&.metadata || ""
    attachment_present = !attachment.nil?
    key = if attachment.nil?
      ""
    else
      attachment.store(setting(:storage))
    end
    message_id = transaction do
      id = create_message(room_id: room.id, creator_id: user.id, client_message_id: client_message_id)
      create_message_body(message_id: id, body: body)
      if attachment_present
        insert_blob(key: key, filename: file_name, content_type: file_type, metadata: file_metadata, byte_size: file_size, checksum: file_checksum)
        attach_message_file(message_id: id, key: key)
      end
      index_message(message_id: id, body: indexed)
      id
    end
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
    broadcast_turbo(global_id_param(room.class_name, room.id, app: "campfire"), :messages, action: :append, target: "messages_rooms_#{kind}_#{room.id}", html: render_string(:message_broadcast, locals: { message_id: message.id, param: message.param, creator_id: message.creator_id, creator_name: message.creator_name, creator_title: message.creator_title, avatar_version: message.avatar_version, created_ms: message.created_ms, updated_ms: message.updated_ms, created_iso: message.created_iso, room_id: message.room_id, room_label: message.room_label, body: message.body, base_url: broadcast_base, boosts: message.boosts, presentation: message.presentation, mentions: message.mentions }))
    room_member_ids(room_id: room.id).each { |member| broadcast("user_#{member.user_id}_unreads", "roomId" => room.id) }
    render :message_stream, layout: nil, content_type: "text/vnd.turbo-stream.html; charset=utf-8", locals: { kind: kind, base_url: request_base_url, room_id: message.room_id, message_id: message.id, param: message.param, creator_id: message.creator_id, creator_name: message.creator_name, creator_title: message.creator_title, avatar_version: message.avatar_version, created_ms: message.created_ms, updated_ms: message.updated_ms, created_iso: message.created_iso, room_label: message.room_label, body: message.body, boosts: message.boosts, presentation: message.presentation, mentions: message.mentions }
  end
end
