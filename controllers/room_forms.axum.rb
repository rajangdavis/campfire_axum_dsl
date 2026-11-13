controller do

  layout_locals do
    signed_in = true
    user_id = current_user.id
    user_name = current_user.name
    logo_version = account_logo_version || ""
  end

  # set_room of the redirecting actions (a room the user is not in goes home with the not-found flash), the direct-room
  # refusal of the two updates, and ensure_can_administer (403 unless an administrator or the room's creator).
  before :set_room_or_home, only: %i[show_closed show_open update_closed destroy destroy_direct update_open], provides: :room
  before :refuse_direct_room, only: %i[update_closed update_open]
  before :ensure_can_administer_room, only: %i[update_closed destroy update_open]

  def set_room_or_home
    room = room_form_room(id: params[:id], user_id: current_user.id)
    return redirect("/", alert: :room_not_found) if room.nil?
    room
  end

  def refuse_direct_room
    return redirect("/", alert: :room_not_found) if room.kind == "direct"
  end

  def ensure_can_administer_room
    flags = current_flags
    return head(403) unless flags.admin == 1 || room.creator_id == current_user.id
  end

  # --- rooms new/edit (namespace :rooms resources :opens, :closeds, :directs) ---------------------------------------

  # Rooms::OpensController#new: a new open room, every active user listed. can_administer? is true for a new record, so
  # every signed-in user sees the name field and the switches, as Rails does.
  def new_open
    flags = current_flags
    # ensure_permission_to_create_rooms: `head :forbidden` for a member when the account restricts room creation.
    creation = sidebar_flags(user_id: current_user.id) || raise("the user was not read back")
    return head(403) if creation.admin == 0 && creation.restrict == 1
    users = active_form_users()
    back_room_id = last_form_room_id(current_user.id, cookie(:last_room, signed: false).to_s.to_i)
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip
    render :room_form_open, locals: { title: "New chat room", can_administer: true, editing: false, form_url: "/rooms/opens", type_change_url: "/rooms/closeds/new", view_transition: "new-room", room_name: "New room", search: users.length > 20, show_delete: false, delete_url: "" }
  end

  # Rooms::OpensController#edit: force_room_type becomes Rooms::Open, so an open route serves a closed room too; a
  # direct room is out of room_scope and is refused. A member who is neither an administrator nor the creator gets
  # the read-only form (title, no switches, no submit), and only an administrator or creator gets the delete panel.
  def edit_open
    room = room_form_room(id: params[:id], user_id: current_user.id)
    return halt(404, "") if room.nil?
    return halt(404, "") if room.kind == "direct"
    flags = current_flags
    users = active_form_users()
    can_administer = flags.admin == 1 || room.creator_id == current_user.id
    back_room_id = last_form_room_id(current_user.id, cookie(:last_room, signed: false).to_s.to_i)
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip
    render :room_form_open, locals: { title: "Edit settings for #{room.name}", editing: true, form_url: "/rooms/opens/#{room.id}", type_change_url: "/rooms/closeds/#{room.id}/edit", view_transition: "edit-room-#{room.id}", room_name: room.name, search: users.length > 20, show_delete: can_administer, delete_url: "#{request_base_url}/rooms/#{room.id}" }
  end

  # Rooms::ClosedsController#new: no grantees yet, so @selected_users is [] and @unselected_users is User.active.ordered.
  def new_closed
    flags = current_flags
    # ensure_permission_to_create_rooms: `head :forbidden` for a member when the account restricts room creation.
    creation = sidebar_flags(user_id: current_user.id) || raise("the user was not read back")
    return head(403) if creation.admin == 0 && creation.restrict == 1
    selected_users = no_form_users()
    unselected_users = active_form_users()
    back_room_id = last_form_room_id(current_user.id, cookie(:last_room, signed: false).to_s.to_i)
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip
    render :room_form_closed, locals: { title: "New chat room", can_administer: true, editing: false, form_url: "/rooms/closeds", type_change_url: "/rooms/opens/new", view_transition: "new-room", room_name: "New room", has_selected_and_unselected: false, new_room: true, search: selected_users.length + unselected_users.length > 20, show_delete: false, delete_url: "" }
  end

  # Rooms::ClosedsController#edit: selected and unselected grantees, each in User.active.ordered order, with a
  # separator between the two lists when both are present (the view writes it).
  def edit_closed
    room = room_form_room(id: params[:id], user_id: current_user.id)
    return halt(404, "") if room.nil?
    return halt(404, "") if room.kind == "direct"
    flags = current_flags
    selected_users = room_form_selected_users(room_id: room.id)
    unselected_users = room_form_unselected_users(room_id: room.id)
    can_administer = flags.admin == 1 || room.creator_id == current_user.id
    back_room_id = last_form_room_id(current_user.id, cookie(:last_room, signed: false).to_s.to_i)
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip
    render :room_form_closed, locals: { title: "Edit settings for #{room.name}", editing: true, form_url: "/rooms/closeds/#{room.id}", type_change_url: "/rooms/opens/#{room.id}/edit", view_transition: "edit-room-#{room.id}", room_name: room.name, has_selected_and_unselected: !selected_users.empty? && !unselected_users.empty?, new_room: false, search: selected_users.length + unselected_users.length > 20, show_delete: can_administer, delete_url: "#{request_base_url}/rooms/#{room.id}" }
  end

  # Rooms::DirectsController#new: normally loaded into the sidebar's turbo frame; the template itself is the frame.
  def new_direct
    flags = current_flags
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip
    # The sidebar loads this as a Turbo frame: turbo-rails' frame layout (no stylesheet links, so no Link header) for a
    # Turbo-Frame request, else the app layout.
    if turbo_frame_request?
      render :room_form_direct_new, layout: :turbo_frame
    else
      render :room_form_direct_new_page, locals: { title: "Campfire" }
    end
  end

  # Rooms::DirectsController#edit: room_scope is Current.user.rooms.directs; the members list is @room.users without
  # Current.user when there is more than one (a direct room always has at least the current user).
  def edit_direct
    room = room_form_room(id: params[:id], user_id: current_user.id)
    return halt(404, "") if room.nil?
    return halt(404, "") if room.kind != "direct"
    page = room_page(id: room.id, user_id: current_user.id) || raise("the room page was not read back")
    members = room_form_members(room_id: room.id, user_id: current_user.id)
    flags = current_flags
    back_room_id = last_form_room_id(current_user.id, cookie(:last_room, signed: false).to_s.to_i)
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip
    render :room_form_direct_edit, locals: { title: "Edit settings for #{page.label}", delete_url: "#{request_base_url}/rooms/directs/#{room.id}" }
  end

  params :NewRoom do
    field :name, :string, in: :form, name: "room[name]"
  end

  # Rooms::OpensController#create: ensure_permission_to_create_rooms (403 when the account restricts room creation to
  # administrators), then Rooms::Open.create_for(room_params, users: Current.user) -- the creator's membership -- and the
  # after_save_commit grant to every active user, all in one transaction here. broadcast_prepend_to :rooms puts the new
  # room in every signed-in sidebar's shared_rooms (users/sidebars/rooms/_shared, rendered without a request), then the
  # answer is redirect_to room_url(room).
  def create_open
    flags = sidebar_flags(user_id: current_user.id) || raise("the user was not read back")
    return head(403) if flags.admin == 0 && flags.restrict == 1
    shown_name = "#{params[:name]}"
    room_id = create_open_room(params[:name], current_user.id) # models/room.axum.rb
    broadcast_prepend_to("rooms", target: "shared_rooms", html: render_string(:room_list_broadcast, locals: { id: room_id, name: shown_name, class_names: "align-center gap room btn txt-nowrap", dom_id: "list_rooms_open_#{room_id}" }))
    redirect("/rooms/#{room_id}")
  end

  # Rooms::ClosedsController#update: the closed-room form sends `room[name]` and one `user_ids[]` per checked person (with
  # none checked the key is absent: Rails' `params.fetch(:user_ids, [])`).
  params :ClosedRoomUpdate do
    field :id, :i64, in: :path
    field :name, :string, in: :form, name: "room[name]"
    field :user_ids, list(:i64), in: :form, name: "user_ids[]", default: []
  end

  def index
    room_id = last_room_of(user_id: current_user.id) || raise("the user is in no room")
    redirect("/rooms/#{room_id}")
  end

  # Rooms::ClosedsController#show and Rooms::OpensController#show: set_room (Current.user.rooms; a room the user is
  # not in redirects home with the not-found flash), remember_last_room_visited, then redirect_to room_url(@room).
  def show_closed
    set_cookie :last_room, room.id.to_s, signed: false, http_only: false
    redirect("/rooms/#{room.id}")
  end

  def show_open
    set_cookie :last_room, room.id.to_s, signed: false, http_only: false
    redirect("/rooms/#{room.id}")
  end


  def update_closed
    ids = params[:user_ids].join(",")
    shown_name = "#{params[:name]}"
    saved_name = "#{params[:name]}"
    revoked = revoked_room_members(room_id: room.id, ids: ids)
    revised = revise_closed_room(room.id, ids, saved_name) # models/room.axum.rb
    return halt(404, "") if revised != 1
    revoked.each { |member| close_remote_connections(member.user_id) }
    html = render_string(:room_list_broadcast, locals: { id: room.id, name: shown_name, class_names: "align-center gap room btn txt-nowrap", dom_id: "list_rooms_closed_#{room.id}" })
    room_member_ids(room_id: room.id).each { |member| broadcast_replace_to(global_id_param("User", member.user_id, app: "campfire"), :rooms, target: "list_rooms_closed_#{room.id}", html: html) }
    redirect("/rooms/#{room.id}")
  end

  # RoomsController#destroy: set_room (a room the user is not in redirects to / with the "Room not found or inaccessible"
  # alert, carried as in rooms.axum.rb), ensure_can_administer (403 unless an administrator or the creator), @room.destroy,
  # broadcast_remove_to :rooms, target: [ @room, :list ], then redirect_to root_url. No cable connection is closed: Room's
  # `has_many :memberships, dependent: :delete_all` skips Membership's after_destroy_commit (the reference capture of
  # realtime/room_deleted_then_send has no disconnect frame either).
  def destroy
    remove_room(room.id) # models/room.axum.rb
    broadcast_remove_to("rooms", target: "list_rooms_#{room.kind}_#{room.id}")
    redirect("/")
  end

  # --- rooms/closeds#create, rooms/directs#create and #destroy, rooms/opens#update ------------------------------------

  params :NewClosedRoom do
    field :name, :string, in: :form, name: "room[name]"
    field :user_ids, list(:i64), in: :form, name: "user_ids[]", default: []
  end

  # Rooms::ClosedsController#create: ensure_permission_to_create_rooms, then Rooms::Closed.create_for(room_params,
  # users: User.where(id: params.fetch(:user_ids, []))) -- the creator is Current.user, and only the people checked get a
  # membership (an unknown id grants nothing). broadcast_create_room renders users/sidebars/rooms/_shared once and
  # prepends it to each member's own sidebar (broadcast_prepend_to user, :rooms, target: :shared_rooms), in
  # `room.users` order; then redirect_to room_url(room).
  def create_closed
    flags = sidebar_flags(user_id: current_user.id) || raise("the user was not read back")
    return head(403) if flags.admin == 0 && flags.restrict == 1
    ids = params[:user_ids].join(",")
    shown_name = "#{params[:name]}"
    room_id = create_closed_room(params[:name], current_user.id, ids) # models/room.axum.rb
    html = render_string(:room_list_broadcast, locals: { id: room_id, name: shown_name, class_names: "align-center gap room btn txt-nowrap", dom_id: "list_rooms_closed_#{room_id}" })
    room_member_ids(room_id: room_id).each { |member| broadcast_prepend_to(global_id_param("User", member.user_id, app: "campfire"), :rooms, target: "shared_rooms", html: html) }
    redirect("/rooms/#{room_id}")
  end

  params :NewDirectRoom do
    field :user_ids, list(:i64), in: :form, name: "user_ids[]", default: []
  end

  # Rooms::DirectsController#create: find_or_create_for(selected_users), then, for each of the room's memberships (a found
  # room too), users/sidebars/rooms/_direct rendered for that membership and prepended to its user's sidebar
  # (membership.broadcast_prepend_to membership.user, :rooms, target: :direct_rooms); then redirect_to room_url(room).
  # The entry is the one GET /users/me/sidebar writes for that person, through the same `cache membership` record.
  def create_direct
    chosen = params[:user_ids].join(",")
    ids = chosen == "" ? "#{current_user.id}" : "#{chosen},#{current_user.id}"
    room_id = find_or_create_direct_room(ids, current_user.id) # models/room.axum.rb
    room_member_ids(room_id: room_id).each do |member|
      cache_sidebar_direct(user_id: member.user_id)
      sidebar_direct_rooms(user_id: member.user_id).select { |d| d.room_id == room_id }.each { |entry| broadcast_prepend_to(global_id_param("User", member.user_id, app: "campfire"), :rooms, target: "direct_rooms", html: render_string(:direct_list_broadcast, from: entry)) }
    end
    redirect("/rooms/#{room_id}")
  end

  # Rooms::DirectsController#destroy is RoomsController#destroy with room_scope `Current.user.rooms.directs` (any other
  # room, or one the user is not in, redirects to / with the "Room not found or inaccessible" alert) and
  # ensure_can_administer always true: every member may delete a ping. The deletes are DELETE /rooms/:id's.
  def destroy_direct
    return redirect("/", alert: :room_not_found) if room.kind != "direct"
    remove_room(room.id) # models/room.axum.rb
    broadcast_remove_to("rooms", target: "list_rooms_direct_#{room.id}")
    redirect("/")
  end

  params :OpenRoomUpdate do
    field :id, :i64, in: :path
    field :name, :string, in: :form, name: "room[name]"
  end

  # Rooms::OpensController#update: set_room over Current.user.rooms.without_directs (else / with the alert),
  # ensure_can_administer (403 unless an administrator or the creator), update!, and Rooms::Open's after_save_commit,
  # which grants every active user a membership when the save changed the type to open. broadcast_update_room replaces
  # the room's entry in every sidebar (broadcast_replace_to :rooms, target: [ @room, :list ], the room now open), then
  # redirect_to room_url(@room).
  def update_open
    opened = room.kind != "open"
    shown_name = "#{params[:name]}"
    saved_name = "#{params[:name]}"
    revised = revise_open_room(room.id, saved_name) # models/room.axum.rb
    return halt(404, "") if revised != 1
    if opened
      grant_room_to_active_users(room_id: room.id)
    end
    broadcast_replace_to("rooms", target: "list_rooms_open_#{room.id}", html: render_string(:room_list_broadcast, locals: { id: room.id, name: shown_name, class_names: "align-center gap room btn txt-nowrap", dom_id: "list_rooms_open_#{room.id}" }))
    redirect("/rooms/#{room.id}")
  end
end
