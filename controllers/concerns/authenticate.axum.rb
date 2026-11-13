fragment do

  # Rails' `before_action :require_authentication`, as one named filter. Every route and the /assets mount take
  # it unless they say `skip: [:authenticate]`; a route that reads current_user is refused if it skips it.
  before :authenticate do
    # A bot key in the path is the other way in (Authentication#bot_authentication, routes.rb `scope path: ":bot_key"`, whose
    # key is "<id>-<bot_token>"): the bot routes below /rooms/:id look the key up themselves (bot_actor) and redirect when it
    # names nobody. The pattern needs the "<id>-" form so that no other route is reached without a session.
    # A `bot_key` parameter authenticates too (bot_authentication: `params[:bot_key]`, stripped), and every controller but
    # the bot ones then answers `head :forbidden` (deny_bots), rather than asking for a login.
    bot_path = request_path.match?(/\A\/rooms\/\d+\/\d+-[^\/]+\/messages(\/|\z)/)
    key = current_user.nil? && !bot_path ? (bot_key_param(request_query) || "") : ""
    return head(403) unless key == "" || bot_actor(token: "", key: key.strip).nil?
    return redirect("/session/new") if current_user.nil? && !bot_path
    "continue"
  end
end
