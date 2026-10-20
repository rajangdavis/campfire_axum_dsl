fragment do
  # MessagesController#index: the newest 40 messages, and a strong ETag from the newest message id, so a
  # browser's If-None-Match is answered 304. The room is remembered in a plain last_room cookie, as Rails did.
  get "/rooms/:id", params: :RoomPath, description: "A room: its newest 40 messages, oldest first" do
    user = current(:user)
    room = room_for_user(id: params[:id], user_id: user.id)
    return redirect("/") if room.nil?
    clear_unread(user_id: user.id, room_id: room.id)
    messages = last_page(room_id: room.id)
    newest = messages.last
    newest_id = newest.nil? ? 0 : newest.id
    etag("\"room-#{newest_id}\"")
    set_cookie :last_room, room.id.to_s, signed: false
    render :room_show, locals: { title: room.name, room_id: room.id, room_name: room.name, messages: messages }
  end

  get "/rooms/:id/messages", params: :PageParams, description: "The 40 messages before one, as a fragment (204 when there are none)" do
    user = current(:user)
    room = room_for_user(id: params[:id], user_id: user.id)
    return redirect("/") if room.nil?
    clear_unread(user_id: user.id, room_id: room.id)
    page = messages_before(room_id: room.id, before: params[:before])
    return halt(204, "") if page.empty?
    render :messages_page, layout: nil, locals: { messages: page }
  end

  # MessagesController#create: a member writes to the room, and the answer is the Turbo Stream that appends the
  # message. The message, its Action Text body and its FTS row are one transaction: a failure between the inserts
  # rolls all three back, leaving no partial message (GAPS.md 13).
  post "/rooms/:id/messages", params: :NewMessage, description: "Post a message to the room and stream it back" do
    user = current(:user)
    room = room_for_user(id: params[:id], user_id: user.id)
    return redirect("/") if room.nil?
    client_message_id = params[:client_message_id] || ""
    message_id = transaction do
      id = create_message(room_id: room.id, creator_id: user.id, client_message_id: client_message_id)
      create_message_body(message_id: id, body: params[:body])
      index_message(message_id: id, body: params[:body])
      id
    end
    message = message_row(id: message_id) || raise("the new message was not read back")
    render :message_stream, layout: nil, content_type: "text/vnd.turbo-stream.html", locals: { room_id: room.id, message_id: message.id, creator_name: message.creator_name, created_at: message.created_at, body: message.body }
  end
end
