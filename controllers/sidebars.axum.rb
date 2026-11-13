controller do

  layout_locals do
    signed_in = true
    user_id = current_user.id
    user_name = current_user.name
    logo_version = account_logo_version || ""
  end

  def show
    @rooms_stream = turbo_signed_stream_name("rooms", secret: :secret_key)
    @user_rooms_stream = turbo_signed_stream_name(global_id_param("User", current_user.id, app: "campfire"), :rooms, secret: :secret_key)
    flags = sidebar_flags(user_id: current_user.id) || raise("the user was not read back")
    # The app layout's body classes, read only when the sidebar is a page of its own (not the layout's lazy frame).
    page_class = turbo_frame_request? ? "" : (sidebar_page_class(user_id: current_user.id) || "")
    @can_create = flags.can_create
    cache_sidebar_direct(user_id: current_user.id)
    @directs = sidebar_direct_rooms(user_id: current_user.id)
    @shared = sidebar_shared_rooms(user_id: current_user.id)
    @placeholders = sidebar_direct_placeholders(user_id: current_user.id)
    # Rails: the layout is turbo-rails' frame layout for a Turbo-Frame request (the page loads this as a lazy frame), else the app layout.
    if turbo_frame_request?
      render :sidebar, layout: :turbo_frame, locals: { avatar_version: flags.avatar_version }
    else
      render :sidebar_page, locals: { body_class: page_class, title: "Campfire", avatar_version: flags.avatar_version }
    end
  end
end
