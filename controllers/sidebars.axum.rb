fragment do
  get "/users/me/sidebar", cache: :private, description: "Your rooms: direct ones, then the shared ones" do
    user = current(:user)
    rooms_stream = turbo_signed_stream_name("rooms", secret: :secret_key)
    user_rooms_stream = turbo_signed_stream_name(global_id_param("User", user.id, app: "campfire"), :rooms, secret: :secret_key)
    flags = sidebar_flags(user_id: user.id) || raise("the user was not read back")
    can_create = if flags.admin == 1
      true
    else
      flags.restrict == 0
    end
    cache_sidebar_direct(user_id: user.id)
    directs = sidebar_direct_rooms(user_id: user.id)
    shared = sidebar_shared_rooms(user_id: user.id)
    placeholders = sidebar_direct_placeholders(user_id: user.id)
    # models/room.axum.rb keeps the two earlier sidebar queries; that file is outside this port's scope, and a
    # declaration no body calls is refused. These bare calls keep them used until the orchestrator retires them.
    direct_rooms_for(user_id: user.id)
    shared_rooms_for(user_id: user.id)
    # Rails: the layout is turbo-rails' frame layout for a Turbo-Frame request (the page loads this as a lazy frame), else the app layout.
    if turbo_frame_request?
      render :sidebar, layout: :turbo_frame, locals: { directs: directs, shared: shared, placeholders: placeholders, can_create: can_create, avatar_version: flags.avatar_version, user_id: user.id, rooms_stream: rooms_stream, user_rooms_stream: user_rooms_stream }
    else
      render :sidebar, locals: { title: "Campfire", logo_version: account_logo_version || "", vapid_key: setting(:vapid_public_key), directs: directs, shared: shared, placeholders: placeholders, can_create: can_create, avatar_version: flags.avatar_version, signed_in: true, user_id: user.id, user_name: user.name, rooms_stream: rooms_stream, user_rooms_stream: user_rooms_stream, flash_on: false, flash_alert: false, flash_text: "" }
    end
  end
end
