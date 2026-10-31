fragment do
  # --- rooms new/edit (namespace :rooms resources :opens, :closeds, :directs) ---------------------------------------

  # Rooms::OpensController#new: a new open room, every active user listed. can_administer? is true for a new record, so
  # every signed-in user sees the name field and the switches, as Rails does.
  get "/rooms/opens/new", description: "The new open-room form" do
    user = current(:user)
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    users = active_form_users(current_user_id: user.id)
    back_room_id = last_form_room_id(user_id: user.id, saved: cookie(:last_room, signed: false).to_s.to_i) || 0
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    render :room_form_open, locals: { title: "New chat room", body_class: body_class, vapid_key: setting(:vapid_public_key), logo_version: account_logo_version || "", signed_in: true, user_id: user.id, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "", back_room_id: back_room_id, can_administer: true, editing: false, form_url: "/rooms/opens", type_change_url: "/rooms/closeds/new", view_transition: "new-room", room_name: "New room", users: users, search: users.length > 20, show_delete: false, delete_url: "" }
  end

  # Rooms::OpensController#edit: force_room_type becomes Rooms::Open, so an open route serves a closed room too; a
  # direct room is out of room_scope and is refused. A member who is neither an administrator nor the creator gets
  # the read-only form (title, no switches, no submit), and only an administrator or creator gets the delete panel.
  get "/rooms/opens/:id/edit", params: :RoomPath, description: "The open-room settings form" do
    user = current(:user)
    room = room_form_room(id: params[:id], user_id: user.id)
    return halt(404, "") if room.nil?
    return halt(404, "") if room.kind == "direct"
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    users = active_form_users(current_user_id: user.id)
    can_administer = flags.admin == 1 || room.creator_id == user.id
    back_room_id = last_form_room_id(user_id: user.id, saved: cookie(:last_room, signed: false).to_s.to_i) || 0
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    render :room_form_open, locals: { title: "Edit settings for #{room.name}", body_class: body_class, vapid_key: setting(:vapid_public_key), logo_version: account_logo_version || "", signed_in: true, user_id: user.id, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "", back_room_id: back_room_id, can_administer: can_administer, editing: true, form_url: "/rooms/opens/#{room.id}", type_change_url: "/rooms/closeds/#{room.id}/edit", view_transition: "edit-room-#{room.id}", room_name: room.name, users: users, search: users.length > 20, show_delete: can_administer, delete_url: "#{request_base_url}/rooms/#{room.id}" }
  end

  # Rooms::ClosedsController#new: no grantees yet, so @selected_users is [] and @unselected_users is User.active.ordered.
  get "/rooms/closeds/new", description: "The new closed-room form" do
    user = current(:user)
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    selected_users = no_form_users()
    unselected_users = active_form_users(current_user_id: user.id)
    back_room_id = last_form_room_id(user_id: user.id, saved: cookie(:last_room, signed: false).to_s.to_i) || 0
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    render :room_form_closed, locals: { title: "New chat room", body_class: body_class, vapid_key: setting(:vapid_public_key), logo_version: account_logo_version || "", signed_in: true, user_id: user.id, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "", back_room_id: back_room_id, can_administer: true, editing: false, form_url: "/rooms/closeds", type_change_url: "/rooms/opens/new", view_transition: "new-room", room_name: "New room", selected_users: selected_users, unselected_users: unselected_users, has_selected_and_unselected: false, new_room: true, search: selected_users.length + unselected_users.length > 20, show_delete: false, delete_url: "" }
  end

  # Rooms::ClosedsController#edit: selected and unselected grantees, each in User.active.ordered order, with a
  # separator between the two lists when both are present (the view writes it).
  get "/rooms/closeds/:id/edit", params: :RoomPath, description: "The closed-room settings form" do
    user = current(:user)
    room = room_form_room(id: params[:id], user_id: user.id)
    return halt(404, "") if room.nil?
    return halt(404, "") if room.kind == "direct"
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    selected_users = room_form_selected_users(room_id: room.id, current_user_id: user.id)
    unselected_users = room_form_unselected_users(room_id: room.id, current_user_id: user.id)
    can_administer = flags.admin == 1 || room.creator_id == user.id
    back_room_id = last_form_room_id(user_id: user.id, saved: cookie(:last_room, signed: false).to_s.to_i) || 0
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    render :room_form_closed, locals: { title: "Edit settings for #{room.name}", body_class: body_class, vapid_key: setting(:vapid_public_key), logo_version: account_logo_version || "", signed_in: true, user_id: user.id, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "", back_room_id: back_room_id, can_administer: can_administer, editing: true, form_url: "/rooms/closeds/#{room.id}", type_change_url: "/rooms/opens/#{room.id}/edit", view_transition: "edit-room-#{room.id}", room_name: room.name, selected_users: selected_users, unselected_users: unselected_users, has_selected_and_unselected: !selected_users.empty? && !unselected_users.empty?, new_room: false, search: selected_users.length + unselected_users.length > 20, show_delete: can_administer, delete_url: "#{request_base_url}/rooms/#{room.id}" }
  end

  # Rooms::DirectsController#new: normally loaded into the sidebar's turbo frame; the template itself is the frame.
  get "/rooms/directs/new", description: "The new ping form" do
    user = current(:user)
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    # The sidebar loads this as a Turbo frame: turbo-rails' frame layout (no stylesheet links, so no Link header) for a
    # Turbo-Frame request, else the app layout.
    if turbo_frame_request?
      render :room_form_direct_new, layout: :turbo_frame
    else
      render :room_form_direct_new_page, locals: { title: "Campfire", body_class: body_class, vapid_key: setting(:vapid_public_key), logo_version: account_logo_version || "", signed_in: true, user_id: user.id, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "" }
    end
  end

  # Rooms::DirectsController#edit: room_scope is Current.user.rooms.directs; the members list is @room.users without
  # Current.user when there is more than one (a direct room always has at least the current user).
  get "/rooms/directs/:id/edit", params: :RoomPath, description: "The ping settings form" do
    user = current(:user)
    room = room_form_room(id: params[:id], user_id: user.id)
    return halt(404, "") if room.nil?
    return halt(404, "") if room.kind != "direct"
    page = room_page(id: room.id, user_id: user.id) || raise("the room page was not read back")
    members = room_form_members(room_id: room.id, user_id: user.id)
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    back_room_id = last_form_room_id(user_id: user.id, saved: cookie(:last_room, signed: false).to_s.to_i) || 0
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    render :room_form_direct_edit, locals: { title: "Edit settings for #{page.label}", body_class: body_class, vapid_key: setting(:vapid_public_key), logo_version: account_logo_version || "", signed_in: true, user_id: user.id, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "", back_room_id: back_room_id, members: members, delete_url: "#{request_base_url}/rooms/directs/#{room.id}" }
  end

  params :NewRoom do
    field :name, :string, in: :form, name: "room[name]"
  end

  # Rooms::OpensController#create: ensure_permission_to_create_rooms (403 when the account restricts room creation to
  # administrators), then Rooms::Open.create_for(room_params, users: Current.user) -- the creator's membership -- and the
  # after_save_commit grant to every active user, all in one transaction here. broadcast_prepend_to :rooms puts the new
  # room in every signed-in sidebar's shared_rooms (users/sidebars/rooms/_shared, rendered without a request), then the
  # answer is redirect_to room_url(room).
  post "/rooms/opens", params: :NewRoom, description: "Create an open room, put it in every sidebar and go to it" do
    user = current(:user)
    flags = sidebar_flags(user_id: user.id) || raise("the user was not read back")
    return halt(403, "") if flags.admin == 0 && flags.restrict == 1
    shown_name = "#{params[:name]}"
    room_id = transaction do
      id = create_room(name: params[:name], creator_id: user.id, room_type: "Rooms::Open")
      grant_room_member(room_id: id, user_id: user.id)
      grant_room_to_active_users(room_id: id)
      id
    end
    broadcast_turbo("rooms", action: :prepend, target: "shared_rooms", html: render_string(:room_list_broadcast, locals: { id: room_id, name: shown_name, class_names: "align-center gap room btn txt-nowrap", dom_id: "list_rooms_open_#{room_id}" }))
    redirect("/rooms/#{room_id}")
  end

  # Rooms::ClosedsController#update: the closed-room form sends `room[name]` and one `user_ids[]` per checked person (with
  # none checked the key is absent: Rails' `params.fetch(:user_ids, [])`).
  params :ClosedRoomUpdate do
    field :id, :i64, in: :path
    field :name, :string, in: :form, name: "room[name]"
    field :user_ids, list(:i64), in: :form, name: "user_ids[]", default: []
  end

  # force_room_type (`@room.becomes!(Rooms::Closed)`, so an open room saved here turns closed) and `@room.update! room_params`;
  # updated_at moves only when the name or the type changed.
  execute :update_closed_room, args: { room_id: :i64, name: :string }, sql: <<~SQL
    UPDATE rooms SET
      updated_at = CASE WHEN COALESCE(name, '') <> :name OR type <> 'Rooms::Closed' THEN strftime('%Y-%m-%d %H:%M:%f', 'now') ELSE updated_at END,
      name = :name, type = 'Rooms::Closed'
    WHERE id = :room_id
  SQL

  # `@room.memberships.revise(granted: User.where(id: ids), revoked: @room.users.where.not(id: ids))`, in the order
  # `grant_to` then `revoke_from`. `ids` is the id list joined with commas (numbers only), read as a JSON array: the DSL
  # passes no list to SQL. Membership.insert_all skips a person who is already a member.
  execute :grant_room_members, args: { room_id: :i64, ids: :string }, sql: <<~SQL
    INSERT OR IGNORE INTO memberships (room_id, user_id, involvement, created_at, updated_at)
    SELECT :room_id, u.id, 'mentions', strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now')
    FROM users u WHERE u.id IN (SELECT value FROM json_each('[' || :ids || ']')) ORDER BY u.id
  SQL

  execute :revoke_room_members, args: { room_id: :i64, ids: :string }, sql: <<~SQL
    DELETE FROM memberships WHERE room_id = :room_id AND user_id NOT IN (SELECT value FROM json_each('[' || :ids || ']'))
  SQL

  # The people `revoke_room_members` is about to remove (`@room.users.where.not(id: ids)`), read before the transaction deletes
  # their rows: Membership `after_destroy_commit { user.reset_remote_connections }` needs them afterwards.
  query :revoked_room_members, args: { room_id: :i64, ids: :string }, returns: list(:RoomMember), sql: <<~SQL
    SELECT user_id FROM memberships WHERE room_id = :room_id AND user_id NOT IN (SELECT value FROM json_each('[' || :ids || ']')) ORDER BY id
  SQL

  # RoomsController#set_room is `Current.user.rooms.without_directs.find_by` (a room the user is not in, or a direct one, redirects to /
  # with the "Room not found or inaccessible" alert, carried as in rooms.axum.rb), then ensure_can_administer (403 unless an
  # administrator or the creator), update!, revise, and broadcast_update_room: every person still in the room has the room's sidebar
  # entry replaced (broadcast_replace_to user, :rooms, target: [ @room, :list ]), the html rendered once. A person taken out gets no
  # broadcast; Rails instead closes their cable connections once the transaction has committed (Membership after_destroy_commit ->
  # user.reset_remote_connections, a `{"type":"disconnect","reason":"remote","reconnect":true}` frame), which
  # `close_remote_connections` does. Their client then reconnects, the endpoint rejects the room's channels (`member_of:`), and
  # the UnreadRoomsChannel reconnect reloads the sidebar frame, which no longer lists the room.
  patch "/rooms/closeds/:id", params: :ClosedRoomUpdate, description: "Save a closed room's name and members and go to it" do
    user = current(:user)
    room = room_form_room(id: params[:id], user_id: user.id)
    session = cookie(:_campfire_session, signed: false).to_s
    token = session.end_with?(".room_not_found") ? session[0, session.length - 15].to_s : session
    missing = room.nil? ? true : room.kind == "direct"
    set_cookie :_campfire_session, missing ? "#{token}.room_not_found" : token, signed: false
    return redirect("/") if room.nil?
    return redirect("/") if room.kind == "direct"
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    return halt(403, "") unless flags.admin == 1 || room.creator_id == user.id
    ids = params[:user_ids].join(",")
    shown_name = "#{params[:name]}"
    saved_name = "#{params[:name]}"
    revoked = revoked_room_members(room_id: room.id, ids: ids)
    revised = transaction do
      grant_room_members(room_id: room.id, ids: ids)
      revoke_room_members(room_id: room.id, ids: ids)
      update_closed_room(room_id: room.id, name: saved_name)
    end
    return halt(404, "") if revised != 1
    revoked.each { |member| close_remote_connections(member.user_id) }
    html = render_string(:room_list_broadcast, locals: { id: room.id, name: shown_name, class_names: "align-center gap room btn txt-nowrap", dom_id: "list_rooms_closed_#{room.id}" })
    room_member_ids(room_id: room.id).each { |member| broadcast_turbo(global_id_param("User", member.user_id, app: "campfire"), :rooms, action: :replace, target: "list_rooms_closed_#{room.id}", html: html) }
    redirect("/rooms/#{room.id}")
  end

  # RoomsController#destroy: set_room (a room the user is not in redirects to / with the "Room not found or inaccessible"
  # alert, carried as in rooms.axum.rb), ensure_can_administer (403 unless an administrator or the creator), @room.destroy,
  # broadcast_remove_to :rooms, target: [ @room, :list ], then redirect_to root_url. No cable connection is closed: Room's
  # `has_many :memberships, dependent: :delete_all` skips Membership's after_destroy_commit (the reference capture of
  # realtime/room_deleted_then_send has no disconnect frame either).
  delete "/rooms/:id", params: :RoomPath, description: "Delete a room with its messages and take it out of every sidebar" do
    user = current(:user)
    room = room_form_room(id: params[:id], user_id: user.id)
    session = cookie(:_campfire_session, signed: false).to_s
    token = session.end_with?(".room_not_found") ? session[0, session.length - 15].to_s : session
    set_cookie :_campfire_session, room.nil? ? "#{token}.room_not_found" : token, signed: false
    return redirect("/") if room.nil?
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    return halt(403, "") unless flags.admin == 1 || room.creator_id == user.id
    gone_id = transaction do
      delete_room_boosts(room_id: room.id)
      delete_room_bodies(room_id: room.id)
      delete_room_attachments(room_id: room.id)
      delete_room_message_index(room_id: room.id)
      delete_room_messages(room_id: room.id)
      delete_room_memberships(room_id: room.id)
      delete_room_row(room_id: room.id)
    end
    broadcast_turbo("rooms", action: :remove, target: "list_rooms_#{room.kind}_#{gone_id}")
    redirect("/")
  end
end