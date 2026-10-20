fragment do
  # Rails' `before_action :require_authentication`, as one named filter. Every route and the /assets mount take
  # it unless they say `skip: [:authenticate]`; a route that reads current(:user) is refused if it skips it.
  before :authenticate do
    return redirect("/session/new") if current(:user).nil?
    "continue"
  end
end
