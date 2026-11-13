controller do

  layout_locals do
    signed_in = false
    user_id = ""
    user_name = ""
  end

  # --- routes ---------------------------------------------------------------------------------------------------------

  # sessions/new.html.erb writes `value: params[:email_address]`; UsersController#create's duplicate-e-mail redirect
  # supplies it. The view takes a bool beside the string because `{% if %}` reads a bool or a nil-able value.
  def new
    return redirect("/first_run") if user_count == 0 # SessionsController#ensure_user_exists
    acct = account_page
    return halt(500, "no account") if acct.nil?
    has_admin = acct.admin_email != ""
    email = params[:email_address] || ""
    render :session_new, from: acct, locals: { body_class: account_logo_class, title: "Sign in", panel_class: "panel ", account_name: acct.name, session_url: "#{request_base_url}/session", has_admin: has_admin, version: setting(:app_version), email_value: email, email_filled: email != "" }
  end

  # A session is a row holding a random token; the cookie holds that token, signed. A wrong login answers 401 with the
  # form, the status travelling on the value a `return` carries; a good one redirects to /, and `redirect` is a 302 as
  # Rails (and the benchmark's login) answer.
  def create
    # SessionsController's `rate_limit to: 10, within: 3.minutes, only: :create, with: -> { render_rejection
    # :too_many_requests }`: a before_action after ApplicationController's, so the ban filter answers first and a
    # banned request is not counted. render_rejection is the failed sign-in's page with a 429.
    over = setting(:rate_limit) > 0 && rate_limited?("sessions", to: 10, within: 180)
    user = active_user_by_email(email: params[:email_address])
    acct = account_page
    return halt(500, "no account") if acct.nil?
    has_admin = acct.admin_email != ""
    # authenticate_by hashes even when no user matches, so an unknown email takes as long as a wrong password (the
    # digest once-campfire-rust checks against: cost 12, as Rails' production BCrypt).
    digest = user.nil? ? '$2a$12$FiKmSp4UhLvSB4Sd/ZUjQunyKP6.NjDRHdr5LnKUVk.BUn4Mq12WS' : user.password_digest
    verified = Bcrypt.verify(params[:password], digest)
    return render(:session_new, status: 429, from: acct, locals: { body_class: account_logo_class, title: "Sign in", panel_class: "panel shake", account_name: acct.name, session_url: "#{request_base_url}/session", has_admin: has_admin, version: setting(:app_version), flash_on: true, flash_alert: true, flash_text: "Too many requests or unauthorized.", email_value: "", email_filled: false }) if over
    return render(:session_new, status: 401, from: acct, locals: { body_class: account_logo_class, title: "Sign in", panel_class: "panel shake", account_name: acct.name, session_url: "#{request_base_url}/session", has_admin: has_admin, version: setting(:app_version), flash_on: true, flash_alert: true, flash_text: "Too many requests or unauthorized.", email_value: "", email_filled: false }) if user.nil? || !verified
    token = random_token
    started = start_session(token: token, user_id: user.id, ip: request_ip, agent: user_agent)
    return halt(500, "the session was not started") if started != 1
    set_cookie :session_token, token, http_only: true, same_site: :lax, permanent: true
    redirect("/")
  end

  # SessionsController#destroy: remove_push_subscription (the device's, by the endpoint the sign-out form sends), then
  # terminate_current_session, then `redirect_to root_url` (which, signed out, goes on to the login form).
  params :Logout do
    field :push_subscription_endpoint, :string, in: :form, optional: true
  end

  def destroy
    token = cookie(:session_token)
    return redirect("/session/new") if token.nil?
    endpoint = params[:push_subscription_endpoint]
    delete_push_subscription_by_endpoint(endpoint: endpoint || "", user_id: current_user.id) unless endpoint.nil?
    end_session(token: token)
    # terminate_current_session ends with disconnect_remote_connections: Current.user.reset_remote_connections, so the signed-out
    # user's other tabs and devices are told to reconnect (and are refused: the session is gone).
    close_remote_connections(current_user.id)
    delete_cookie :session_token
    redirect("/")
  end

  # RoomsController#index: where "/" goes. The last_room cookie, when it still names a room this user is a
  # member of, wins; otherwise the first membership. A cookie naming another room falls back, so it grants nothing.
  def root
    saved = cookie(:last_room, signed: false).to_s
    visited = room_for_user(id: saved.to_i, user_id: current_user.id)
    fallback = first_room_id(user_id: current_user.id) || 0
    room_id = visited.nil? ? fallback : visited.id
    return redirect("/rooms/#{room_id}") if room_id != 0
    # With no room to go to, the welcome page is where the alert a redirect to / carries is shown, once; a redirect on
    # to a room leaves it for that room's page to take.
    flash = take_flash
    render(:welcome, locals: { title: "No rooms yet", signed_in: true, user_id: current_user.id.to_s, user_name: current_user.name, flash_on: flash.on, flash_alert: flash.alert, flash_text: flash.text, logo_version: account_logo_version || "" })
  end
end
