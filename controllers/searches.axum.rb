controller do

  layout_locals do
    signed_in = true
    user_id = current_user.id.to_s
    user_name = current_user.name
    logo_version = account_logo_version || ""
  end

  params :NewSearch do
    field :q, :string, in: :form
  end

  # SearchesController#create: Current.user.searches.record(query), then redirect_to searches_url(q: query). Rails
  # builds the query with Rack::Utils.escape (a space as `+`), which is url_encode; the answer is an ordinary
  # ApplicationController redirect, so it carries X-Version/X-Rev and the session_token refresh like every other.
  def create
    terms = params[:q].gsub(/[^[:word:]]/, " ")
    touch_search(user_id: current_user.id, query: terms)
    create_search(user_id: current_user.id, query: terms)
    trim_searches(user_id: current_user.id)
    redirect("/searches?q=#{url_encode(terms)}")
  end

  # Campfire's `q.gsub(/[^[:word:]]/, " ")`: [[:word:]] keeps Unicode word characters ("café" stays whole).
  def index
    raw = params[:q] || ""
    terms = raw.gsub(/[^[:word:]]/, " ")
    found = terms.strip.empty? ? no_messages() : search_messages(user_id: current_user.id, q: terms, by_id: setting(:search_order_by_id))
    flags = current_flags
    visited = room_for_user(id: cookie(:last_room, signed: false).to_s.to_i, user_id: current_user.id)
    recents = recent_searches(user_id: current_user.id)
    return_to = visited.nil? ? (first_room_id(user_id: current_user.id) || 0) : visited.id
    body_class = "sidebar searches#{flags.admin == 1 ? " admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    render :searches, locals: { title: "Search", has_query: !terms.strip.empty?, raw_q: raw, has_raw: raw != "", count: found.length, has_recents: !recents.empty?, base_url: request_base_url, messages: found }
  end

  # SearchesController#clear: `Current.user.searches.destroy_all`, then redirect_to searches_url.
  def clear
    clear_searches(user_id: current_user.id)
    redirect("/searches")
  end
end
