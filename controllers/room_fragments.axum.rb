controller do

  layout_locals do
    signed_in = true
    user_id = current_user.id.to_s
    user_name = current_user.name
    logo_version = account_logo_version || ""
  end

  params :RefreshPath do
    field :id, :i64, in: :path
    field :since, :i64, in: :query, optional: true
  end

  params :MessagePath do
    field :id, :i64, in: :path
    field :message_id, :i64, in: :path
  end

  # Rooms::InvolvementsHelper: the frame, and the button that cycles to the next involvement.
  def involvement
    page = room_page(id: params[:id], user_id: current_user.id)
    return redirect("/") if page.nil?
    flags = current_flags
    involvement = involvement_for(room_id: page.id, user_id: current_user.id) || "mentions"
    direct = page.kind == "direct"
    next_involvement = direct ? (involvement == "everything" ? "nothing" : "everything") : (involvement == "mentions" ? "everything" : (involvement == "everything" ? "nothing" : (involvement == "nothing" ? "invisible" : "mentions")))
    label = involvement == "mentions" ? "Notifying about @ mentions" : (involvement == "everything" ? "Notifying about all messages" : (involvement == "nothing" ? "Notifications are off" : "Notifications are off and room invisible in sidebar"))
    # Rails: turbo-rails' frame layout for a Turbo-Frame request (the page loads this as a frame), else the app layout.
    if turbo_frame_request?
      render :room_involvement_frame, layout: :turbo_frame, locals: { room_id: page.id, kind: page.kind, bell_mentions: involvement == "mentions", bell_everything: involvement == "everything", bell_nothing: involvement == "nothing", bell_invisible: involvement == "invisible" }
    else
      render :room_involvement, locals: { title: "Campfire", body_class: "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip, room_id: page.id, kind: page.kind, bell_mentions: involvement == "mentions", bell_everything: involvement == "everything", bell_nothing: involvement == "nothing", bell_invisible: involvement == "invisible" }
    end
  end

  # Rooms::InvolvementsController#update: `@membership.update! involvement: params[:involvement]` (the enum raises on a
  # value outside invisible/nothing/mentions/everything), then broadcast_visibility_changes to the user's own rooms
  # stream, then redirect_to room_involvement_url.
  params :InvolvementUpdate do
    field :id, :i64, in: :path
    field :involvement, :string, in: :form # the button sends ?involvement=; set :merge_query_params reads it
  end

  def update_involvement
    page = room_page(id: params[:id], user_id: current_user.id)
    return halt(404, "") if page.nil?
    value = params[:involvement]
    raise "invalid involvement" unless value == "invisible" || value == "nothing" || value == "mentions" || value == "everything"
    previous = involvement_for(room_id: page.id, user_id: current_user.id) || "mentions"
    set_involvement(room_id: page.id, user_id: current_user.id, involvement: value)
    involvement_hides_room(room_id: page.id, user_id: current_user.id).each { |member| broadcast_remove_to(global_id_param("User", member.user_id, app: "campfire"), :rooms, target: "list_rooms_#{page.kind}_#{page.id}") }
    involvement_shows_room(room_id: page.id, user_id: current_user.id, previous: previous).each { |member| broadcast_prepend_to(global_id_param("User", member.user_id, app: "campfire"), :rooms, target: "shared_rooms", html: render_string(:room_list_broadcast, locals: { id: page.id, name: page.label, class_names: "align-center gap room btn txt-nowrap", dom_id: "list_rooms_#{page.kind}_#{page.id}" })) }
    redirect("/rooms/#{page.id}/involvement")
  end

  # Rooms::RefreshesController#show: the messages created and updated since a time, as Turbo Streams.
  def refresh
    page = room_page(id: params[:id], user_id: current_user.id)
    # RoomScoped#set_room is `Current.user.memberships.find_by!(room_id:)`: RecordNotFound, which production answers with
    # public/404.html (as GET /users/:id does), not the redirect RoomsController#set_room makes.
    return html(file_text(:page_404), status: 404, content_type: "text/html; charset=UTF-8") if page.nil?
    since = params[:since] || 0
    fresh = messages_created_since(room_id: page.id, since: since)
    updated = messages_updated_since(room_id: page.id, since: since)
    render :room_refresh, layout: nil, content_type: "text/vnd.turbo-stream.html; charset=utf-8", locals: { kind: page.kind, room_id: page.id, base_url: request_base_url, has_fresh: !fresh.empty? }
  end

  # MessagesController#show: one message of the room.
  def message
    page = room_page(id: params[:id], user_id: current_user.id)
    return redirect("/") if page.nil?
    message = message_row(id: params[:message_id])
    return halt(404, "") if message.nil? || message.room_id != page.id
    flags = current_flags
    # The application layout even for a Turbo-Frame request (the edit form's cancel link and the update redirect):
    # MessagesController's `layout false, only: :index` replaces turbo-rails' frame-layout choice.
    render :message_show, frame_layout: false, from: message, locals: { title: "Campfire", body_class: "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip, base_url: request_base_url, message_id: message.id }
  end
end
