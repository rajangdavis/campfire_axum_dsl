# Laws over the flash (campfire.axum.rb's `flash` declaration) and current_user: Rails' redirect_to ..., alert:/notice:
# and the page it lands on, as the session cookie's states. A token is `tok`; while a message waits it is `tok.<key>`.
#   tok --redirect(alert:/notice:)--> tok.<key> --take_flash (a room page, an account page, the welcome page)--> tok
#   tok.<key> --any route that does not read the flash (/ on its way to a room)--> tok.<key>
fragment do
  # A room the member is not in: RoomsController#set_room's redirect to / with the alert, written on the token.
  law :an_unknown_room_redirects_with_the_alert do
    r = respond(:get, "/rooms/2000000000", headers: { "Cookie" => "#{cookie_header(:session_token, "law-member-token")}; _campfire_session=tok" })
    r.status == 302 && r.location.end_with?("/") && r.headers.include?("set-cookie: _campfire_session=tok.room_not_found;")
  end

  # The room page shows a waiting alert once and writes the bare token back; the next visit shows none.
  law :a_room_page_shows_the_alert_once do
    member = cookie_header(:session_token, "law-member-token")
    first = respond(:get, "/rooms/1", headers: { "Cookie" => "#{member}; _campfire_session=tok.room_not_found" })
    again = respond(:get, "/rooms/1", headers: { "Cookie" => "#{member}; _campfire_session=tok" })
    first.status == 200 && first.body.include?("Room not found or inaccessible") &&
      first.headers.include?("set-cookie: _campfire_session=tok;") && !again.body.include?("Room not found or inaccessible")
  end

  # / with a room to go to does not read the flash, so the alert travels on to that room (Rails keeps a flash nothing read).
  law :root_passes_the_alert_on do
    r = respond(:get, "/", headers: { "Cookie" => "#{cookie_header(:session_token, "law-member-token")}; _campfire_session=tok.room_not_found" })
    r.status == 302 && r.location.include?("/rooms/") && !r.headers.include?("set-cookie: _campfire_session=tok;")
  end

  # A save's notice: written on the redirect, shown once by the page it lands on.
  law :a_notice_is_shown_once do
    admin = cookie_header(:session_token, "law-administrator-token")
    saved = respond(:patch, "/account", body: "account%5Bname%5D=Campfire+Test", headers: { "Cookie" => "#{admin}; _campfire_session=tok" })
    first = respond(:get, "/account/edit", headers: { "Cookie" => "#{admin}; _campfire_session=tok.notice_saved" })
    again = respond(:get, "/account/edit", headers: { "Cookie" => "#{admin}; _campfire_session=tok" })
    saved.status == 302 && saved.headers.include?("set-cookie: _campfire_session=tok.notice_saved;") &&
      first.body.include?("class=\"flash\"") && first.headers.include?("set-cookie: _campfire_session=tok;") &&
      !again.body.include?("class=\"flash\"")
  end

  # current_user is required behind `before :authenticate`: without a session a page is a redirect to sign in.
  law :no_session_is_sent_to_sign_in do
    %w[/ /rooms/1 /account/edit /users/me/profile].all? do |path|
      r = respond(:get, path)
      r.status == 302 && r.location.end_with?("/session/new")
    end
  end
end
