controller do
  # Message#plain_text_body: `body.to_plain_text.presence || attachment&.filename&.to_s || ""`.
  helper :bot_plain_text_body, args: [:string, :string], returns: :string do |body, filename|
    text = plain_text(body)
    text.strip.empty? ? filename : text
  end

  # messages/_message.json.jbuilder with users/_user.json.jbuilder for the creator (id, name, role, the fresh avatar
  # URL). `body.html` is Action Text's `body.to_s`: the stored HTML inside the `lexxy-content` wrapper (an empty
  # body renders nothing).
  helper :bot_message_json, args: [:i64, :string, :string, :string, :i64, :string, :string, :string, :i64, :string], returns: :string do |id, created_at, body, filename, creator_id, creator_name, creator_role, avatar_url, room_id, url|
    html = body.empty? ? "" : "<div class=\"lexxy-content\">\n  #{body}\n</div>\n"
    json_object("id" => id, "created_at" => created_at,
                "body" => json_object("plain_text" => bot_plain_text_body(body, filename), "html" => html),
                "creator" => json_object("id" => creator_id, "name" => creator_name, "role" => creator_role, "avatar_url" => avatar_url),
                "room" => json_object("id" => room_id), "url" => url)
  end

  # messages/boosts/_boost.json.jbuilder: the boost, its booster as users/_user.json draws them, and its message.
  helper :bot_boost_json, args: [:i64, :string, :string, :i64, :string, :string, :string, :i64, :string], returns: :string do |id, content, created_at, booster_id, booster_name, booster_role, avatar_url, message_id, message_url|
    json_object("id" => id, "content" => content, "created_at" => created_at,
                "booster" => json_object("id" => booster_id, "name" => booster_name, "role" => booster_role, "avatar_url" => avatar_url),
                "message" => json_object("id" => message_id, "url" => message_url))
  end

  # Each route does its own authentication, then set_room (`Current.user.rooms.find_by`, 404) for that user.
  before :set_bot_user, provides: :user
  before :set_bot_room, provides: :room

  def set_bot_user
    user = bot_actor(token: cookie(:session_token).to_s, key: params[:bot_key].strip)
    return redirect("/session/new") if user.nil?
    user
  end

  def set_bot_room
    room = room_for_user(id: params[:id], user_id: user.id)
    return halt(404, "") if room.nil?
    room
  end

  # Messages::ByBotsController#index, at routes.rb `scope path: ":bot_key"` under /rooms/:id. These routes do their own
  # authentication: Authentication#require_authentication takes the session cookie first, else
  # `User.authenticate_bot(params[:bot_key].strip)`, and redirects to the sign-in page when neither names a user
  # (the bot_actor query; the `:authenticate` filter lets a bot-key path through to it). `allow_bot_access` lets a bot through; protect_from_forgery is skipped for a bot key and
  # this service has no CSRF token, only :fetch_metadata. The room is `Current.user.rooms.find_by(id:)`, 404 when
  # missing. Pagination headers: X-Total-Count and, when a next page exists, `Link: <...>; rel="next"`
  # (set_pagination_headers, next_page_params: `after` pages forward, anything else back).
  def index
    before = params[:before]
    after = params[:after]
    before_id = before.nil? ? 0 : before
    after_id = after.nil? ? 0 : after
    # find_paged_messages: `@room.messages.find(params[:before])` raises (404) for a message outside the room.
    return halt(404, "") if before_id != 0 && room_message_id(room_id: room.id, id: before_id).nil?
    return halt(404, "") if before_id == 0 && after_id != 0 && room_message_id(room_id: room.id, id: after_id).nil?
    page = before_id == 0 && after_id != 0 ? bot_messages_after(room_id: room.id, after: after_id) : bot_messages_last(room_id: room.id, before: before_id)
    ids = page.map { |m| m.id }
    first_id = ids.first || 0
    last_id = ids.last || 0
    older = bot_older_exists(room_id: room.id, id: first_id)
    newer = bot_newer_exists(room_id: room.id, id: last_id)
    next_param = after_id != 0 ? (newer ? "after=#{last_id}" : "") : (older ? "before=#{first_id}" : "")
    link = next_param.empty? ? nil : "<#{request_base_url}/rooms/#{room.id}/#{params[:bot_key]}/messages?#{next_param}>; rel=\"next\""
    headers "X-Total-Count" => room_message_count(room_id: room.id).to_s, "Link" => link
    items = page.map { |m|
      bot_message_json(m.id, m.created_at, m.body, m.filename, m.creator_id, m.creator_name, m.creator_role,
                       "#{request_base_url}/users/#{rails_signed_id_for(m.creator_id, purpose: "user/avatar", secret: :secret_key)}/avatar?v=#{m.avatar_version}",
                       m.room_id, "#{request_base_url}/rooms/#{m.room_id}/messages/#{m.id}")
    }
    text(json_array(items), content_type: "application/json; charset=utf-8")
  end

  # Messages::ByBotsController (< MessagesController) update: set_room, set_message (`@room.messages.find`, 404),
  # ensure_can_administer (an administrator or the creator, else 403), then `@message.update!(body: raw_request_body)`:
  # the body is the request body as it came, JSON text included (RawRequestBody). The FTS row follows
  # (Message::Searchable#update_in_index) and the answer is by_bots/show.json.
  def update
    message = bot_message(room_id: room.id, id: params[:message_id])
    return halt(404, "") if message.nil?
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    return head(403) unless flags.admin == 1 || message.creator_id == user.id
    body = action_text_html(request_body) # ActionText::Content.new: stripped, parsed and serialized
    indexed = bot_plain_text_body(body, message.filename)
    saved_id = update_message(message.id, body, indexed) # models/message.axum.rb
    m = bot_message(room_id: room.id, id: saved_id) || raise("the message was not read back")
    json = bot_message_json(m.id, m.created_at, m.body, m.filename, m.creator_id, m.creator_name, m.creator_role,
                            "#{request_base_url}/users/#{rails_signed_id_for(m.creator_id, purpose: "user/avatar", secret: :secret_key)}/avatar?v=#{m.avatar_version}",
                            m.room_id, "#{request_base_url}/rooms/#{m.room_id}/messages/#{m.id}")
    text(json, content_type: "application/json; charset=utf-8")
  end

  # Messages::Boosts::ByBotsController#create: set_message (the user's room, then the message, 404 when either is missing),
  # a blank request body is 422, otherwise `@message.boosts.create!(content: raw_request_body)` answered 201 with
  # by_bots/show.json (messages/boosts/_boost.json).
  def add_boost
    message = bot_message(room_id: room.id, id: params[:message_id])
    return halt(404, "") if message.nil?
    content = request_body
    return halt(422, "") if content.strip.empty?
    boost_id = boost_message(message.id, user.id, content) # models/message.axum.rb
    # Messages::Boosts::ByBotsController#create's broadcast_create, as the composer's boost sends it (messages.axum.rb).
    boosted = message_row(id: message.id) || raise("the boosted message was not read back")
    room_class = room_class_for_user(id: room.id, user_id: user.id) || raise("the room was not read back")
    shown = boost_row(id: boost_id) || raise("the boost was not read back")
    broadcast_append_to(global_id_param(room_class.class_name, room.id, app: "campfire"), :messages, target: "boosts_message_#{boosted.param}", html: render_string(:boost_broadcast, locals: { id: shown.id, booster_id: shown.booster_id, booster_title: shown.booster_title, booster_version: shown.booster_version, label: shown.label, content: shown.content, message_id: message.id }), maintain_scroll: true)
    b = bot_boost(id: boost_id) || raise("the boost was not read back")
    json = bot_boost_json(b.id, b.content, b.created_at, b.booster_id, b.booster_name, b.booster_role,
                          "#{request_base_url}/users/#{rails_signed_id_for(b.booster_id, purpose: "user/avatar", secret: :secret_key)}/avatar?v=#{b.avatar_version}",
                          b.message_id, "#{request_base_url}/rooms/#{b.room_id}/messages/#{b.message_id}")
    text(json, status: 201, content_type: "application/json; charset=utf-8")
  end
end
