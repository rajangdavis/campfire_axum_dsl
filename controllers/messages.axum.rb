controller do

  layout_locals do
    signed_in = true
    user_id = current_user.id.to_s
    user_name = current_user.name
    logo_version = account_logo_version || ""
  end

  # The lookups and guards the actions open with, run in this order before the action (Rails' before_actions): the bot, the
  # room, the message, the flags, then the administrator-or-creator check.
  before :set_bot_user, only: %i[create_by_bot destroy_by_bot destroy_boost_by_bot], provides: :user
  before :set_boost_message, only: %i[new_boost add_boost destroy_boost], provides: :message
  before :set_member_room, only: %i[update destroy], provides: :room
  before :set_visible_room, only: [:edit], provides: :room
  before :set_bot_room, only: %i[create_by_bot destroy_by_bot destroy_boost_by_bot], provides: :room
  before :set_boost_room, only: %i[add_boost destroy_boost], provides: :room
  before :set_room_message, only: %i[edit destroy destroy_by_bot destroy_boost_by_bot], provides: :message
  before :set_room_bot_message, only: [:update], provides: :message
  before :set_flags, only: %i[edit update destroy], provides: :flags
  before :ensure_can_administer_message, only: %i[edit update destroy]

  def set_bot_user
    user = bot_actor(token: cookie(:session_token).to_s, key: params[:bot_key].strip)
    return redirect("/session/new") if user.nil?
    user
  end

  def set_boost_message
    message = message_row(id: params[:message_id])
    return halt(404, "") if message.nil?
    message
  end

  def set_member_room
    room = room_class_for_user(id: params[:id], user_id: current_user.id)
    return halt(404, "") if room.nil?
    room
  end

  def set_visible_room
    room = room_for_user(id: params[:id], user_id: current_user.id)
    return halt(404, "") if room.nil?
    room
  end

  def set_bot_room
    room = room_class_for_user(id: params[:id], user_id: user.id)
    return halt(404, "") if room.nil?
    room
  end

  def set_boost_room
    room = room_class_for_user(id: message.room_id, user_id: current_user.id)
    return halt(404, "") if room.nil?
    room
  end

  def set_room_message
    message = message_row(id: params[:message_id])
    return halt(404, "") if message.nil? || message.room_id != room.id
    message
  end

  def set_room_bot_message
    message = bot_message(room_id: room.id, id: params[:message_id])
    return halt(404, "") if message.nil?
    message
  end

  def set_flags
    current_flags
  end

  def ensure_can_administer_message
    return head(403) unless flags.admin == 1 || message.creator_id == current_user.id
  end

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

  # MessagesController#edit: the form that replaces the message in its `edit_message_<id>` frame. set_room is
  # `Current.user.memberships.find_by!` (404), set_message `@room.messages.find` (404), then ensure_can_administer
  # (`head :forbidden` unless an administrator or the creator). Always the application layout: MessagesController
  # declares `layout false, only: :index`, and any `layout` declaration replaces turbo-rails' frame-layout choice, so
  # Rails answers the edit frame's Turbo-Frame request with the full page (and its preload Link); Turbo takes the frame.
  # `frame_layout: false` keeps that layout under `set :turbo_frame_layout`.
  # views/message_edit_form.html leaves the delete form open, as edit.html.erb's block-less `form_with ... method: :delete`
  # does: the parser ends the element at </div> but keeps its form pointer, so the layout's later lightbox
  # <form method="dialog"> is dropped as a nested form, and the page's tree (and its hash) match Rails'.
  # The editor's `value` is `{{ body|editable :message_body, ... }}` (RichTextHelper#editable_body, then Lexxy's
  # render_custom_attachments_in): each mention and link preview is rebuilt from the users and the sanitizer's partials,
  # so Lexxy shows the mention chip. Full page and Turbo Frame answer are the same view.
  def edit
    render :message_edit, frame_layout: false, from: message, locals: { title: "Campfire", body_class: "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip, room_id: room.id, base_url: request_base_url }
  end

  # MessagesController#update: `@message.update!(message_params)` saves the Action Text body (touching the message and,
  # through it, the room) and Message::Searchable#update_in_index keeps the FTS row at the plain text. HTML answers
  # `redirect_to room_message_url(@room, @message)`, which the edit frame follows to the message's show.
  # Rails also routes `put` here and answers JSON to a JSON request; the browser's form sends `_method=patch`.
  def update
    body = params[:body]
    indexed = bot_plain_text_body(body, message.filename)
    saved_id = update_message(message.id, body, indexed) # models/message.axum.rb
    # @message.broadcast_replace_to @room, :messages, target: [ @message, :presentation ], partial: "messages/presentation",
    # attributes: { maintain_scroll: true }: to every RoomMessagesChannel subscriber, the editor included. The partial is the
    # presentation div with the saved body, rendered without a request.
    edited = message_row(id: saved_id) || raise("the edited message was not read back")
    # Its absolute URLs come from SetCurrentRequest's protocol and host, without the port (see rooms.axum.rb).
    origin = request_base_url.split(":")
    broadcast_base = "#{origin[0] || ""}:#{origin[1] || ""}"
    broadcast_replace_to(room, :messages, app: "campfire", target: "presentation_message_#{edited.param}", html: render_string(:message_presentation_broadcast, from: edited, locals: { base_url: broadcast_base }), maintain_scroll: true)
    redirect("/rooms/#{room.id}/messages/#{saved_id}")
  end

  # MessagesController#destroy: the message goes, its boosts, body, attachment and FTS row with it, and the room is
  # touched (belongs_to :room, touch: true). The answer is destroy.turbo_stream.erb: `turbo_stream.remove @message`.
  def destroy
    destroy_room_message(message.id) # models/message.axum.rb
    # @message.broadcast_remove, i.e. broadcast_remove_to @room, :messages (target: dom_id(message), to every subscriber, the deleter included).
    broadcast_remove_to(room, :messages, app: "campfire", target: "message_#{message.param}")
    render :message_destroy, layout: nil, content_type: "text/vnd.turbo-stream.html; charset=utf-8", locals: { param: message.param }
  end

  # Messages::BoostsController#index: the message's boosts, the `boosting_message_<id>` frame (messages/boosts/_boosts).
  def boosts
    message = message_row(id: params[:message_id])
    return html(file_text(:page_404), status: 404, content_type: "text/html; charset=UTF-8") if message.nil? # reachable_messages.find
    room = room_for_user(id: message.room_id, user_id: current_user.id)
    return html(file_text(:page_404), status: 404, content_type: "text/html; charset=UTF-8") if room.nil?
    flags = current_flags
    if turbo_frame_request?
      render :boosts_frame, layout: :turbo_frame, from: message
    else
      render :boosts_page, from: message, locals: { title: "Campfire", body_class: "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip }
    end
  end

  # Messages::BoostsController#new: the boost form (messages/boosts/new), in the `new_boost_message_<id>` frame.
  def new_boost
    room = room_for_user(id: message.room_id, user_id: current_user.id)
    return halt(404, "") if room.nil?
    flags = current_flags
    if turbo_frame_request?
      render :boost_new_frame, layout: :turbo_frame, locals: { id: message.id, param: message.param, me_id: current_user.id, me_name: current_user.name, me_title: flags.title, me_version: flags.version }
    else
      render :boost_new, locals: { title: "Campfire", body_class: "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip, id: message.id, param: message.param, me_id: current_user.id, me_name: current_user.name, me_title: flags.title, me_version: flags.version }
    end
  end

  # Messages::BoostsController#create: `@message.boosts.create!(content:)` (Boost belongs_to :message, touch: true: the
  # message and its room are touched), then `redirect_to message_boosts_url(@message)`, which the boosting frame follows.
  def add_boost
    message_id = message.id
    content = params[:content]
    user_id = current_user.id # before BEGIN: a current is not read inside the transaction
    boost_id = boost_message(message_id, user_id, content) # models/message.axum.rb
    # broadcast_create, i.e. @boost.broadcast_append_to the room, :messages, target "boosts_message_<client_message_id>",
    # partial "messages/boosts/boost", attributes: { maintain_scroll: true } (to every subscriber, the booster included).
    boost = boost_row(id: boost_id) || raise("the new boost was not read back")
    broadcast_append_to(room, :messages, app: "campfire", target: "boosts_message_#{message.param}", html: render_string(:boost_broadcast, from: boost, locals: { message_id: message_id }), maintain_scroll: true)
    redirect("/messages/#{message_id}/boosts")
  end

  # Messages::BoostsController#destroy: only the booster's own boost (`find_by!(id:, booster: Current.user)`, 404), then
  # `@boost.destroy!` (touching the message and room). There is no template, so Rails' implicit render answers 204.
  def destroy_boost
    removed = delete_own_boost(message_id: message.id, id: params[:id], booster_id: current_user.id)
    return halt(404, "") if removed.nil?
    touch_message(message_id: removed)
    touch_message_room(message_id: removed)
    # broadcast_remove, i.e. @boost.broadcast_remove_to the room, :messages (target: dom_id(boost), to every subscriber).
    broadcast_remove_to(room, :messages, app: "campfire", target: "boost_#{params[:id]}")
    halt(204, "")
  end

  # --- the bot API's writes: messages/by_bots#create and #destroy, messages/boosts/by_bots#destroy ----------------------

  # Messages::ByBotsController#create. Authentication as the other bot routes (the session cookie, else the bot key;
  # neither: the sign-in redirect), set_room (`Current.user.rooms.find_by`, `head :not_found`),
  # ensure_body_or_attachment_present (a blank raw body is 422), then MessagesController#create with `{ body:
  # raw_request_body }`: the message (a random client_message_id, Random.uuid), its Action Text body and FTS row, the
  # room touched and received, the broadcast a composer post sends; and `head :created, location: message_url(@message)`.
  # Room#receive's Web Push and deliver_webhooks_to_bots (the other bots' webhooks) go out after the answer
  # (models/push.axum.rb). A multipart `attachment` file is the message instead of the raw body.
  def create_by_bot
    # message_params: a multipart `attachment` file is the message (no body; Message#plain_text_body is its filename),
    # else the raw body is. ensure_body_or_attachment_present: neither is a 422.
    attachment = request_upload(:attachment)
    raw = request_body
    return halt(422, "") if attachment.nil? && raw.strip.empty?
    body = attachment.nil? ? action_text_html(raw) : "" # ActionText::Content.new: stripped, parsed and serialized
    file_name = attachment&.filename || ""
    body_text = attachment.nil? ? plain_text(body) : file_name
    html_body = attachment.nil? ? body : nil # the webhook payload's message.body.body&.to_html: null for a file
    room_id = room.id
    # MessagesController#create's create_with_attachment! (models/message.axum.rb, create_room_message), with a random
    # client_message_id (Random.uuid): the message's rows in one transaction, and an image's :thumb variant.
    message_id = create_room_message(room_id, user.id, random_uuid, body, body_text, attachment)
    message = message_row(id: message_id) || raise("the new message was not read back")
    kind = room.class_name == "Rooms::Open" ? "open" : (room.class_name == "Rooms::Closed" ? "closed" : "direct")
    origin = request_base_url.split(":")
    broadcast_base = "#{origin[0] || ""}:#{origin[1] || ""}"
    broadcast_append_to(room, :messages, app: "campfire", target: "messages_rooms_#{kind}_#{room.id}", html: render_string(:message_broadcast, from: message, locals: { message_id: message.id, base_url: broadcast_base }))
    room_member_ids(room_id: room.id).each { |member| broadcast("user_#{member.user_id}_unreads", "roomId" => room.id) }
    # Room#receive's push_later, as the composer's post sends it (controllers/rooms.axum.rb).
    push_title = kind == "direct" ? message.creator_name : message.room_label
    push_body = kind == "direct" ? body_text : "#{message.creator_name}: #{body_text}"
    room_name = kind == "direct" ? nil : message.room_label # Rails' message.room.name: nil for a ping
    later do
      push_targets(room_id: room.id, creator_id: user.id, body: body).each do |target|
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
      webhook_bots(room_id: room.id, creator_id: user.id, body: body, direct: kind == "direct" ? 1 : 0).each do |bot|
        plain = Rust.Str(body_text).replace("@#{bot.name}", "").to_s.strip # without_recipient_mentions
        reply = webhook_post(bot.url, json_object("user" => json_object("id" => user.id, "name" => user.name),
                                                  "room" => json_object("id" => room.id, "name" => room_name, "path" => "/rooms/#{room.id}/#{bot.bot_key}/messages"),
                                                  "message" => json_object("id" => message.id, "body" => json_object("html" => html_body, "plain" => plain), "path" => "/rooms/#{room.id}/@#{message.id}")))
        has_reply = !reply.nil?
        reply_text = action_text_html(reply || "") # receive_text_reply_to's body, as Action Text stores it
        reply_plain = plain_text(reply_text)
        reply_uuid = random_uuid
        if has_reply
          reply_id = create_text_message(room_id, bot.id, reply_uuid, reply_text, reply_plain)
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
    headers "Location" => "#{request_base_url}/messages/#{message.id}"
    text("", status: 201, content_type: "application/json; charset=utf-8")
  end

  # Messages::ByBotsController#destroy: set_room (404), set_message (`@room.messages.find`, 404), ensure_can_administer (an
  # administrator or the message's creator, else 403), MessagesController#destroy's delete and broadcast_remove, and
  # `head :no_content`.
  def destroy_by_bot
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    return head(403) unless flags.admin == 1 || message.creator_id == user.id
    gone = message_dom_param(id: message.id) || raise("the message was not read back")
    destroy_room_message(message.id) # models/message.axum.rb
    broadcast_remove_to(room, :messages, app: "campfire", target: "message_#{gone.param}")
    halt(204, "")
  end

  params :BotBoostPath do
    field :id, :i64, in: :path
    field :bot_key, :string, in: :path
    field :message_id, :i64, in: :path
    field :boost_id, :i64, in: :path
  end

  # Messages::Boosts::ByBotsController#destroy: set_message (the user's room, then the message in it; `head :not_found`),
  # set_boost (`find_by!(id:, booster: Current.user)`, its RecordNotFound answered `head :not_found`), `destroy!` (the
  # boost touches its message, which touches the room), broadcast_remove; no template, so 204.
  def destroy_boost_by_bot
    removed = delete_own_boost(message_id: message.id, id: params[:boost_id], booster_id: user.id)
    return halt(404, "") if removed.nil?
    touch_message(message_id: removed)
    touch_message_room(message_id: removed)
    broadcast_remove_to(room, :messages, app: "campfire", target: "boost_#{params[:boost_id]}")
    halt(204, "")
  end
end
