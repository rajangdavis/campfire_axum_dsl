fragment do
  # --- routes ---------------------------------------------------------------------------------------------------------

  get "/session/new", description: "The login form", skip: [:authenticate] do
    render :session_new, locals: { title: "Sign in" }
  end

  # A session is a row holding a random token; the cookie holds that token, signed. A wrong login answers 401 with the
  # form, the status travelling on the value a `return` carries; a good one redirects to /, and `redirect` is a 302 as
  # Rails (and the benchmark's login) answer.
  post "/session", params: :Login, description: "Log in: start a session and set the session_token cookie", skip: [:authenticate] do
    user = active_user_by_email(email: params[:email_address])
    return render(:session_new, status: 401, locals: { title: "Sign in" }) if user.nil? || !Bcrypt.verify(params[:password], user.password_digest)
    token = random_token
    started = start_session(token: token, user_id: user.id, ip: request_ip, agent: user_agent)
    return halt(500, "the session was not started") if started != 1
    set_cookie :session_token, token, http_only: true, same_site: :lax, permanent: true
    redirect("/")
  end

  delete "/session", description: "Log out: delete the session row and the cookie" do
    token = cookie(:session_token)
    return redirect("/session/new") if token.nil?
    end_session(token: token)
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
    return halt(200, "You are not in any room yet.") if room_id == 0
    redirect("/rooms/#{room_id}")
  end
end
