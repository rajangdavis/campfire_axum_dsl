fragment do
  # --- routes ---------------------------------------------------------------------------------------------------------

  # sessions/new.html.erb writes `value: params[:email_address]`; UsersController#create's duplicate-e-mail redirect
  # supplies it. The view takes a bool beside the string because `{% if %}` reads a bool or a nil-able value.
  get "/session/new", params: :SessionNewParams, description: "The login form", skip: [:authenticate] do
    acct = account_page
    return halt(500, "no account") if acct.nil?
    has_admin = acct.admin_email != ""
    email = params[:email_address] || ""
    render :session_new, locals: { title: "Sign in", vapid_key: setting(:vapid_public_key), panel_class: "panel ", account_name: acct.name, logo_version: acct.logo_version, session_url: "#{request_base_url}/session", admin_name: acct.admin_name, admin_email: acct.admin_email, has_admin: has_admin, version: setting(:app_version), signed_in: false, user_id: "", user_name: "", flash_on: false, flash_alert: false, flash_text: "", email_value: email, email_filled: email != "" }
  end

  # A session is a row holding a random token; the cookie holds that token, signed. A wrong login answers 401 with the
  # form, the status travelling on the value a `return` carries; a good one redirects to /, and `redirect` is a 302 as
  # Rails (and the benchmark's login) answer.
  post "/session", params: :Login, description: "Log in: start a session and set the session_token cookie", skip: [:authenticate] do
    user = active_user_by_email(email: params[:email_address])
    acct = account_page
    return halt(500, "no account") if acct.nil?
    has_admin = acct.admin_email != ""
    # authenticate_by hashes even when no user matches, so an unknown email takes as long as a wrong password (the
    # digest once-campfire-rust checks against: cost 12, as Rails' production BCrypt).
    digest = user.nil? ? '$2a$12$FiKmSp4UhLvSB4Sd/ZUjQunyKP6.NjDRHdr5LnKUVk.BUn4Mq12WS' : user.password_digest
    verified = Bcrypt.verify(params[:password], digest)
    return render(:session_new, status: 401, locals: { title: "Sign in", vapid_key: setting(:vapid_public_key), panel_class: "panel shake", account_name: acct.name, logo_version: acct.logo_version, session_url: "#{request_base_url}/session", admin_name: acct.admin_name, admin_email: acct.admin_email, has_admin: has_admin, version: setting(:app_version), signed_in: false, user_id: "", user_name: "", flash_on: true, flash_alert: true, flash_text: "Too many requests or unauthorized.", email_value: "", email_filled: false }) if user.nil? || !verified
    token = random_token
    started = start_session(token: token, user_id: user.id, ip: request_ip, agent: user_agent)
    return halt(500, "the session was not started") if started != 1
    set_cookie :session_token, token, http_only: true, same_site: :lax, permanent: true
    redirect("/")
  end

  delete "/session", description: "Log out: delete the session row and the cookie" do
    token = cookie(:session_token)
    return redirect("/session/new") if token.nil?
    user = current(:user)
    end_session(token: token)
    # terminate_current_session ends with disconnect_remote_connections: Current.user.reset_remote_connections, so the signed-out
    # user's other tabs and devices are told to reconnect (and are refused: the session is gone).
    close_remote_connections(user.id)
    delete_cookie :session_token
    redirect("/session/new")
  end

  # RoomsController#index: where "/" goes. The last_room cookie, when it still names a room this user is a
  # member of, wins; otherwise the first membership. A cookie naming another room falls back, so it grants nothing.
  get "/", description: "Your first room, or a note that you have none" do
    user = current(:user)
    saved = cookie(:last_room, signed: false).to_s
    visited = room_for_user(id: saved.to_i, user_id: user.id)
    fallback = first_room_id(user_id: user.id) || 0
    room_id = visited.nil? ? fallback : visited.id
    return render(:welcome, locals: { title: "No rooms yet", signed_in: true, user_id: user.id.to_s, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "", vapid_key: setting(:vapid_public_key), logo_version: account_logo_version || "" }) if room_id == 0
    redirect("/rooms/#{room_id}")
  end
end
