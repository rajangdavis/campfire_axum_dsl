fragment do
  # MessagesController#update: the room and message in the path, the edited body in the form (`params.require(:message)
  # .permit(:body, ...)`; the bracketed wire name is declared with `name:`).
  params :UpdateMessage do
    field :id, :i64, in: :path
    field :message_id, :i64, in: :path
    field :body, :string, in: :form, name: "message[body]"
  end

  # routes.rb `resources :messages { resources :boosts }` (module "messages"): the message in the path.
  params :MessageBoostsPath do
    field :message_id, :i64, in: :path
  end

  # Messages::BoostsController#create: `params.require(:boost).permit(:content)`.
  params :NewBoost do
    field :message_id, :i64, in: :path
    field :content, :string, in: :form, name: "boost[content]"
  end

  params :MessageBoostPath do
    field :message_id, :i64, in: :path
    field :id, :i64, in: :path
  end

  # Messages::BoostsController#set_boost and #destroy: `@message.boosts.find_by!(id:, booster: Current.user)` then `destroy!`, in one
  # statement: the message id of the boost that was deleted, or nothing (the controller answers 404).
  query :delete_own_boost, args: { message_id: :i64, id: :i64, booster_id: :i64 }, returns: :i64?, sql: <<~SQL
    DELETE FROM boosts WHERE id = :id AND message_id = :message_id AND booster_id = :booster_id RETURNING message_id
  SQL

  # Message#destroy: has_many :boosts (dependent: :destroy), has_rich_text :body, has_one_attached :attachment (the
  # attachment row goes with the message; Rails purges the blob later, a job this service does not run) and
  # Message::Searchable#remove_from_index.
  execute :delete_message_boosts, args: { message_id: :i64 }, sql: <<~SQL
    DELETE FROM boosts WHERE message_id = :message_id
  SQL

  execute :delete_message_body, args: { message_id: :i64 }, sql: <<~SQL
    DELETE FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = :message_id
  SQL

  execute :delete_message_attachments, args: { message_id: :i64 }, sql: <<~SQL
    DELETE FROM active_storage_attachments WHERE record_type = 'Message' AND record_id = :message_id
  SQL

  execute :delete_message_index, args: { message_id: :i64 }, sql: <<~SQL
    DELETE FROM message_search_index WHERE rowid = :message_id
  SQL

  # The message row; the answer is its dom id part (`to_key`, the client_message_id), which the Turbo Stream names.
  query :delete_message, args: { message_id: :i64 }, returns: :string, sql: <<~SQL
    DELETE FROM messages WHERE id = :message_id RETURNING COALESCE(client_message_id, CAST(id AS TEXT))
  SQL

  # MessagesController#edit: the form that replaces the message in its `edit_message_<id>` frame. set_room is
  # `Current.user.memberships.find_by!` (404), set_message `@room.messages.find` (404), then ensure_can_administer
  # (`head :forbidden` unless an administrator or the creator). Always the application layout: MessagesController
  # declares `layout false, only: :index`, and any `layout` declaration replaces turbo-rails' frame-layout choice, so
  # Rails answers the edit frame's Turbo-Frame request with the full page (and its preload Link); Turbo takes the frame.
  # views/message_edit_form.html leaves the delete form open, as edit.html.erb's block-less `form_with ... method: :delete`
  # does: the parser ends the element at </div> but keeps its form pointer, so the layout's later lightbox
  # <form method="dialog"> is dropped as a nested form, and the page's tree (and its hash) match Rails'.
  # The editor's `value` is `{{ body|editable :message_body, ... }}` (RichTextHelper#editable_body, then Lexxy's
  # render_custom_attachments_in): each mention and link preview is rebuilt from the users and the sanitizer's partials,
  # so Lexxy shows the mention chip. Full page and Turbo Frame answer are the same view.
  get "/rooms/:id/messages/:message_id/edit", params: :MessagePath, cache: :private, description: "The edit form of one message, as a Turbo frame" do
    user = current(:user)
    room = room_for_user(id: params[:id], user_id: user.id)
    return halt(404, "") if room.nil?
    message = message_row(id: params[:message_id])
    return halt(404, "") if message.nil? || message.room_id != room.id
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    return halt(403, "") unless flags.admin == 1 || message.creator_id == user.id
    render :message_edit, locals: { title: "Campfire", body_class: flags.admin == 1 ? "admin" : "", logo_version: account_logo_version || "", vapid_key: setting(:vapid_public_key), id: message.id, param: message.param, room_id: room.id, base_url: request_base_url, body: message.body, presentation: message.presentation, mentions: message.mentions, signed_in: true, user_id: user.id.to_s, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "" }
  end

  # MessagesController#update: `@message.update!(message_params)` saves the Action Text body (touching the message and,
  # through it, the room) and Message::Searchable#update_in_index keeps the FTS row at the plain text. HTML answers
  # `redirect_to room_message_url(@room, @message)`, which the edit frame follows to the message's show.
  # Rails also routes `put` here and answers JSON to a JSON request; the browser's form sends `_method=patch`.
  patch "/rooms/:id/messages/:message_id", params: :UpdateMessage, description: "Save an edited message and go back to it" do
    user = current(:user)
    room = room_class_for_user(id: params[:id], user_id: user.id)
    return halt(404, "") if room.nil?
    message = bot_message(room_id: room.id, id: params[:message_id])
    return halt(404, "") if message.nil?
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    return halt(403, "") unless flags.admin == 1 || message.creator_id == user.id
    body = params[:body]
    indexed = bot_plain_text_body(body, message.filename)
    message_id = message.id
    saved_id = transaction do
      save_message_body(message_id: message_id, body: body)
      touch_message(message_id: message_id)
      touch_message_room(message_id: message_id)
      reindex_message(message_id: message_id, body: indexed)
      message_id
    end
    # @message.broadcast_replace_to @room, :messages, target: [ @message, :presentation ], partial: "messages/presentation",
    # attributes: { maintain_scroll: true }: to every RoomMessagesChannel subscriber, the editor included. The partial is the
    # presentation div with the saved body, rendered without a request.
    edited = message_row(id: saved_id) || raise("the edited message was not read back")
    # Its absolute URLs come from SetCurrentRequest's protocol and host, without the port (see rooms.axum.rb).
    origin = request_base_url.split(":")
    broadcast_base = "#{origin[0] || ""}:#{origin[1] || ""}"
    broadcast_turbo(global_id_param(room.class_name, room.id, app: "campfire"), :messages, action: :replace, target: "presentation_message_#{edited.param}", html: render_string(:message_presentation_broadcast, locals: { param: edited.param, presentation: edited.presentation, body: edited.body, base_url: broadcast_base, mentions: edited.mentions }), maintain_scroll: true)
    redirect("/rooms/#{room.id}/messages/#{saved_id}")
  end

  # MessagesController#destroy: the message goes, its boosts, body, attachment and FTS row with it, and the room is
  # touched (belongs_to :room, touch: true). The answer is destroy.turbo_stream.erb: `turbo_stream.remove @message`.
  delete "/rooms/:id/messages/:message_id", params: :MessagePath, description: "Delete a message and remove it from the page" do
    user = current(:user)
    room = room_class_for_user(id: params[:id], user_id: user.id)
    return halt(404, "") if room.nil?
    message = message_row(id: params[:message_id])
    return halt(404, "") if message.nil? || message.room_id != room.id
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    return halt(403, "") unless flags.admin == 1 || message.creator_id == user.id
    message_id = message.id
    gone = transaction do
      touch_message_room(message_id: message_id)
      delete_message_boosts(message_id: message_id)
      delete_message_body(message_id: message_id)
      delete_message_attachments(message_id: message_id)
      delete_message_index(message_id: message_id)
      delete_message(message_id: message_id)
    end
    # @message.broadcast_remove, i.e. broadcast_remove_to @room, :messages (target: dom_id(message), to every subscriber, the deleter included).
    broadcast_turbo(global_id_param(room.class_name, room.id, app: "campfire"), :messages, action: :remove, target: "message_#{gone}")
    render :message_destroy, layout: nil, content_type: "text/vnd.turbo-stream.html; charset=utf-8", locals: { param: gone }
  end

  # Messages::BoostsController#index: the message's boosts, the `boosting_message_<id>` frame (messages/boosts/_boosts).
  get "/messages/:message_id/boosts", params: :MessageBoostsPath, cache: :private, description: "A message's boosts, as a Turbo frame" do
    user = current(:user)
    message = message_row(id: params[:message_id])
    return halt(404, "") if message.nil?
    room = room_for_user(id: message.room_id, user_id: user.id)
    return halt(404, "") if room.nil?
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    if turbo_frame_request?
      render :boosts_frame, layout: :turbo_frame, locals: { id: message.id, param: message.param, boosts: message.boosts }
    else
      render :boosts_page, locals: { title: "Campfire", body_class: flags.admin == 1 ? "admin" : "", logo_version: account_logo_version || "", vapid_key: setting(:vapid_public_key), id: message.id, param: message.param, boosts: message.boosts, signed_in: true, user_id: user.id.to_s, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "" }
    end
  end

  # Messages::BoostsController#new: the boost form (messages/boosts/new), in the `new_boost_message_<id>` frame.
  get "/messages/:message_id/boosts/new", params: :MessageBoostsPath, cache: :private, description: "The new-boost form of a message, as a Turbo frame" do
    user = current(:user)
    message = message_row(id: params[:message_id])
    return halt(404, "") if message.nil?
    room = room_for_user(id: message.room_id, user_id: user.id)
    return halt(404, "") if room.nil?
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    if turbo_frame_request?
      render :boost_new_frame, layout: :turbo_frame, locals: { id: message.id, param: message.param, me_id: user.id, me_name: user.name, me_title: flags.title, me_version: flags.version }
    else
      render :boost_new, locals: { title: "Campfire", body_class: flags.admin == 1 ? "admin" : "", logo_version: account_logo_version || "", vapid_key: setting(:vapid_public_key), id: message.id, param: message.param, me_id: user.id, me_name: user.name, me_title: flags.title, me_version: flags.version, signed_in: true, user_id: user.id.to_s, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "" }
    end
  end

  # Messages::BoostsController#create: `@message.boosts.create!(content:)` (Boost belongs_to :message, touch: true: the
  # message and its room are touched), then `redirect_to message_boosts_url(@message)`, which the boosting frame follows.
  post "/messages/:message_id/boosts", params: :NewBoost, description: "Boost a message and show its boosts" do
    user = current(:user)
    message = message_row(id: params[:message_id])
    return halt(404, "") if message.nil?
    room = room_class_for_user(id: message.room_id, user_id: user.id)
    return halt(404, "") if room.nil?
    message_id = message.id
    content = params[:content]
    boost_id = transaction do
      touch_message(message_id: message_id)
      touch_message_room(message_id: message_id)
      create_boost(message_id: message_id, booster_id: user.id, content: content)
    end
    # broadcast_create, i.e. @boost.broadcast_append_to the room, :messages, target "boosts_message_<client_message_id>",
    # partial "messages/boosts/boost", attributes: { maintain_scroll: true } (to every subscriber, the booster included).
    boost = boost_row(id: boost_id) || raise("the new boost was not read back")
    broadcast_turbo(global_id_param(room.class_name, room.id, app: "campfire"), :messages, action: :append, target: "boosts_message_#{message.param}", html: render_string(:boost_broadcast, locals: { id: boost.id, booster_id: boost.booster_id, booster_title: boost.booster_title, booster_version: boost.booster_version, label: boost.label, content: boost.content, message_id: message_id }), maintain_scroll: true)
    redirect("/messages/#{message_id}/boosts")
  end

  # Messages::BoostsController#destroy: only the booster's own boost (`find_by!(id:, booster: Current.user)`, 404), then
  # `@boost.destroy!` (touching the message and room). There is no template, so Rails' implicit render answers 204.
  delete "/messages/:message_id/boosts/:id", params: :MessageBoostPath, description: "Delete one of your boosts" do
    user = current(:user)
    message = message_row(id: params[:message_id])
    return halt(404, "") if message.nil?
    room = room_class_for_user(id: message.room_id, user_id: user.id)
    return halt(404, "") if room.nil?
    removed = delete_own_boost(message_id: message.id, id: params[:id], booster_id: user.id)
    return halt(404, "") if removed.nil?
    touch_message(message_id: removed)
    touch_message_room(message_id: removed)
    # broadcast_remove, i.e. @boost.broadcast_remove_to the room, :messages (target: dom_id(boost), to every subscriber).
    broadcast_turbo(global_id_param(room.class_name, room.id, app: "campfire"), :messages, action: :remove, target: "boost_#{params[:id]}")
    halt(204, "")
  end
end
