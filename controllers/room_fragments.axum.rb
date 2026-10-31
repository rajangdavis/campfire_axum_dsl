fragment do
  params :RefreshPath do
    field :id, :i64, in: :path
    field :since, :i64, in: :query, optional: true
  end

  params :MessagePath do
    field :id, :i64, in: :path
    field :message_id, :i64, in: :path
  end

  # Rooms::InvolvementsController#show: the membership's involvement.
  query :involvement_for, args: { room_id: :i64, user_id: :i64 }, returns: :string?, sql: <<~SQL
    SELECT involvement FROM memberships WHERE room_id = :room_id AND user_id = :user_id
  SQL

  # Message.page_created_since(time): the first 40 messages created after :since (epoch ms), oldest first.
  query :messages_created_since, args: { room_id: :i64, since: :i64 }, returns: list(:MessageRow), sql: <<~SQL
    SELECT m.id AS id, COALESCE(m.client_message_id, CAST(m.id AS TEXT)) AS param, m.creator_id AS creator_id, COALESCE(u.name, '') AS creator_name,
             COALESCE(CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END, '') AS creator_title,
             COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS avatar_version,
             m.created_at AS created_at,
             CAST(strftime('%s', m.created_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.created_at), 4) AS INTEGER) AS created_ms,
             CAST(strftime('%s', m.updated_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.updated_at), 4) AS INTEGER) AS updated_ms,
             strftime('%Y-%m-%dT%H:%M:%SZ', m.created_at) AS created_iso,
             m.room_id AS room_id, CASE WHEN u.id IS NULL THEN 0 ELSE 1 END AS renderable,
             CASE WHEN r.type = 'Rooms::Direct' THEN COALESCE((SELECT CASE WHEN o.cnt = 1 THEN o.s ELSE substr(o.s, 1, length(o.s) - length(o.last_name) - 2) || CASE o.cnt WHEN 2 THEN ' and ' ELSE ', and ' END || o.last_name END FROM (SELECT COUNT(*) AS cnt, group_concat(n.name, ', ') AS s, (SELECT u2.name FROM memberships m2 JOIN users u2 ON u2.id = m2.user_id WHERE m2.room_id = r.id ORDER BY u2.id DESC LIMIT 1) AS last_name FROM (SELECT u3.name AS name FROM memberships m3 JOIN users u3 ON u3.id = m3.user_id WHERE m3.room_id = r.id ORDER BY u3.id) AS n) AS o WHERE o.cnt > 0), '') ELSE COALESCE(r.name, '') END AS room_label,
             COALESCE(t.body, '') AS body
      FROM messages m
      LEFT JOIN users u ON u.id = m.creator_id
      JOIN rooms r ON r.id = m.room_id
      LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
      WHERE m.room_id = :room_id AND CAST(strftime('%s', m.created_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.created_at), 4) AS INTEGER) > :since
      ORDER BY m.created_at ASC, m.id ASC LIMIT 40
  SQL

  # Message.without(new).page_updated_since(time): the last 40 messages updated after :since that are not in the
  # created-since page, oldest first.
  query :messages_updated_since, args: { room_id: :i64, since: :i64 }, returns: list(:MessageRow), sql: <<~SQL
    SELECT id, param, creator_id, creator_name, creator_title, avatar_version, created_at, created_ms, updated_ms, created_iso, room_id, renderable, room_label, body FROM (
      SELECT m.id AS id, COALESCE(m.client_message_id, CAST(m.id AS TEXT)) AS param, m.creator_id AS creator_id, COALESCE(u.name, '') AS creator_name,
             COALESCE(CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END, '') AS creator_title,
             COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS avatar_version,
             m.created_at AS created_at,
             CAST(strftime('%s', m.created_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.created_at), 4) AS INTEGER) AS created_ms,
             CAST(strftime('%s', m.updated_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.updated_at), 4) AS INTEGER) AS updated_ms,
             strftime('%Y-%m-%dT%H:%M:%SZ', m.created_at) AS created_iso,
             m.room_id AS room_id, CASE WHEN u.id IS NULL THEN 0 ELSE 1 END AS renderable,
             CASE WHEN r.type = 'Rooms::Direct' THEN COALESCE((SELECT CASE WHEN o.cnt = 1 THEN o.s ELSE substr(o.s, 1, length(o.s) - length(o.last_name) - 2) || CASE o.cnt WHEN 2 THEN ' and ' ELSE ', and ' END || o.last_name END FROM (SELECT COUNT(*) AS cnt, group_concat(n.name, ', ') AS s, (SELECT u2.name FROM memberships m2 JOIN users u2 ON u2.id = m2.user_id WHERE m2.room_id = r.id ORDER BY u2.id DESC LIMIT 1) AS last_name FROM (SELECT u3.name AS name FROM memberships m3 JOIN users u3 ON u3.id = m3.user_id WHERE m3.room_id = r.id ORDER BY u3.id) AS n) AS o WHERE o.cnt > 0), '') ELSE COALESCE(r.name, '') END AS room_label,
             COALESCE(t.body, '') AS body
      FROM messages m
      LEFT JOIN users u ON u.id = m.creator_id
      JOIN rooms r ON r.id = m.room_id
      LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
      WHERE m.room_id = :room_id AND CAST(strftime('%s', m.updated_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.updated_at), 4) AS INTEGER) > :since
        AND m.id NOT IN (SELECT n.id FROM messages n WHERE n.room_id = :room_id AND CAST(strftime('%s', n.created_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', n.created_at), 4) AS INTEGER) > :since ORDER BY n.created_at ASC, n.id ASC LIMIT 40)
      ORDER BY m.created_at DESC, m.id DESC LIMIT 40
    ) ORDER BY created_at ASC, id ASC
  SQL

  # Rooms::InvolvementsHelper: the frame, and the button that cycles to the next involvement.
  get "/rooms/:id/involvement", params: :RoomPath, cache: :private, description: "The room's notification button, as a Turbo frame" do
    user = current(:user)
    page = room_page(id: params[:id], user_id: user.id)
    return redirect("/") if page.nil?
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    involvement = involvement_for(room_id: page.id, user_id: user.id) || "mentions"
    direct = page.kind == "direct"
    next_involvement = direct ? (involvement == "everything" ? "nothing" : "everything") : (involvement == "mentions" ? "everything" : (involvement == "everything" ? "nothing" : (involvement == "nothing" ? "invisible" : "mentions")))
    label = involvement == "mentions" ? "Notifying about @ mentions" : (involvement == "everything" ? "Notifying about all messages" : (involvement == "nothing" ? "Notifications are off" : "Notifications are off and room invisible in sidebar"))
    # Rails: turbo-rails' frame layout for a Turbo-Frame request (the page loads this as a frame), else the app layout.
    if turbo_frame_request?
      render :room_involvement_frame, layout: :turbo_frame, locals: { room_id: page.id, kind: page.kind, involvement: involvement, bell_mentions: involvement == "mentions", bell_everything: involvement == "everything", bell_nothing: involvement == "nothing", bell_invisible: involvement == "invisible", next_involvement: next_involvement, label: label }
    else
      render :room_involvement, locals: { title: "Campfire", body_class: flags.admin == 1 ? "admin" : "", logo_version: account_logo_version || "", vapid_key: setting(:vapid_public_key), room_id: page.id, kind: page.kind, involvement: involvement, bell_mentions: involvement == "mentions", bell_everything: involvement == "everything", bell_nothing: involvement == "nothing", bell_invisible: involvement == "invisible", next_involvement: next_involvement, label: label, signed_in: true, user_id: user.id.to_s, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "" }
    end
  end

  # Rooms::InvolvementsController#update: `@membership.update! involvement: params[:involvement]` (the enum raises on a
  # value outside invisible/nothing/mentions/everything), then broadcast_visibility_changes to the user's own rooms
  # stream, then redirect_to room_involvement_url.
  params :InvolvementUpdate do
    field :id, :i64, in: :path
    field :involvement, :string, in: :query
  end

  execute :set_involvement, args: { room_id: :i64, user_id: :i64, involvement: :string }, sql: <<~SQL
    UPDATE memberships SET involvement = :involvement, updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now')
    WHERE room_id = :room_id AND user_id = :user_id
  SQL

  # `when @membership.involved_in_invisible?` (not for a direct room): broadcast_remove_to the user, :rooms.
  query :involvement_hides_room, args: { room_id: :i64, user_id: :i64 }, returns: list(:RoomMember), sql: <<~SQL
    SELECT m.user_id AS user_id FROM memberships m JOIN rooms r ON r.id = m.room_id
    WHERE m.room_id = :room_id AND m.user_id = :user_id AND m.involvement = 'invisible' AND r.type <> 'Rooms::Direct'
  SQL

  # `when involvement_previously_was.invisible?`: broadcast_prepend_to the user, :rooms into shared_rooms.
  query :involvement_shows_room, args: { room_id: :i64, user_id: :i64, previous: :string }, returns: list(:RoomMember), sql: <<~SQL
    SELECT m.user_id AS user_id FROM memberships m JOIN rooms r ON r.id = m.room_id
    WHERE m.room_id = :room_id AND m.user_id = :user_id AND m.involvement <> 'invisible' AND :previous = 'invisible'
      AND r.type <> 'Rooms::Direct'
  SQL

  put "/rooms/:id/involvement", params: :InvolvementUpdate, description: "Set the room's notification level and go back to the button" do
    user = current(:user)
    page = room_page(id: params[:id], user_id: user.id)
    return halt(404, "") if page.nil?
    value = params[:involvement]
    raise "invalid involvement" unless value == "invisible" || value == "nothing" || value == "mentions" || value == "everything"
    previous = involvement_for(room_id: page.id, user_id: user.id) || "mentions"
    set_involvement(room_id: page.id, user_id: user.id, involvement: value)
    involvement_hides_room(room_id: page.id, user_id: user.id).each { |member| broadcast_turbo(global_id_param("User", member.user_id, app: "campfire"), :rooms, action: :remove, target: "list_rooms_#{page.kind}_#{page.id}") }
    involvement_shows_room(room_id: page.id, user_id: user.id, previous: previous).each { |member| broadcast_turbo(global_id_param("User", member.user_id, app: "campfire"), :rooms, action: :prepend, target: "shared_rooms", html: render_string(:room_list_broadcast, locals: { id: page.id, name: page.label, class_names: "align-center gap room btn txt-nowrap", dom_id: "list_rooms_#{page.kind}_#{page.id}" })) }
    redirect("/rooms/#{page.id}/involvement")
  end

  # Rooms::RefreshesController#show: the messages created and updated since a time, as Turbo Streams.
  get "/rooms/:id/refresh", params: :RefreshPath, description: "Messages created or updated since a time, as Turbo Streams" do
    user = current(:user)
    page = room_page(id: params[:id], user_id: user.id)
    # RoomScoped#set_room is `Current.user.memberships.find_by!(room_id:)`: RecordNotFound, which production answers with
    # public/404.html (as GET /users/:id does), not the redirect RoomsController#set_room makes.
    return html(file_text(:page_404), status: 404, content_type: "text/html; charset=UTF-8") if page.nil?
    since = params[:since] || 0
    fresh = messages_created_since(room_id: page.id, since: since)
    updated = messages_updated_since(room_id: page.id, since: since)
    render :room_refresh, layout: nil, content_type: "text/vnd.turbo-stream.html; charset=utf-8", locals: { kind: page.kind, room_id: page.id, base_url: request_base_url, has_fresh: !fresh.empty?, fresh: fresh, updated: updated }
  end

  # MessagesController#show: one message of the room.
  get "/rooms/:id/messages/:message_id", params: :MessagePath, cache: :private, description: "One message of a room" do
    user = current(:user)
    page = room_page(id: params[:id], user_id: user.id)
    return redirect("/") if page.nil?
    message = message_row(id: params[:message_id])
    return halt(404, "") if message.nil? || message.room_id != page.id
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    # The application layout even for a Turbo-Frame request (the edit form's cancel link and the update redirect):
    # MessagesController's `layout false, only: :index` replaces turbo-rails' frame-layout choice.
    render :message_show, locals: { title: "Campfire", body_class: flags.admin == 1 ? "admin" : "", logo_version: account_logo_version || "", vapid_key: setting(:vapid_public_key), base_url: request_base_url, message_id: message.id, param: message.param, creator_id: message.creator_id, creator_name: message.creator_name, creator_title: message.creator_title, avatar_version: message.avatar_version, created_ms: message.created_ms, updated_ms: message.updated_ms, created_iso: message.created_iso, room_id: message.room_id, room_label: message.room_label, body: message.body, boosts: message.boosts, presentation: message.presentation, mentions: message.mentions, renderable: message.renderable, signed_in: true, user_id: user.id.to_s, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "" }
  end
end
