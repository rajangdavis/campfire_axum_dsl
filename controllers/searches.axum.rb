fragment do
  # Search#ordered: the user's recent searches, newest first (searches_controller.rb index, Current.user.searches.ordered).
  record :RecentSearch do
    field :query, :string
  end

  query :recent_searches, args: { user_id: :i64 }, returns: list(:RecentSearch), sql: <<~SQL
    SELECT query FROM searches WHERE user_id = :user_id ORDER BY updated_at DESC, id DESC
  SQL

  params :NewSearch do
    field :q, :string, in: :form
  end

  # Search.record(query): find_or_create_by(query:).touch, then after_create trim_recent_searches keeps the 10 newest.
  execute :touch_search, args: { user_id: :i64, query: :string }, sql: <<~SQL
    UPDATE searches SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE user_id = :user_id AND query = :query
  SQL

  execute :create_search, args: { user_id: :i64, query: :string }, sql: <<~SQL
    INSERT INTO searches (user_id, query, created_at, updated_at)
    SELECT :user_id, :query, strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM searches WHERE user_id = :user_id AND query = :query)
  SQL

  execute :trim_searches, args: { user_id: :i64 }, sql: <<~SQL
    DELETE FROM searches WHERE user_id = :user_id
      AND id NOT IN (SELECT id FROM searches WHERE user_id = :user_id ORDER BY updated_at DESC, id DESC LIMIT 10)
  SQL

  # SearchesController#create: Current.user.searches.record(query), then redirect_to searches_url(q: query). Rails
  # builds the query with Rack::Utils.escape (a space as `+`), which is url_encode; the answer is an ordinary
  # ApplicationController redirect, so it carries X-Version/X-Rev and the session_token refresh like every other.
  post "/searches", params: :NewSearch, description: "Remember a search and go to its results" do
    user = current(:user)
    terms = params[:q].gsub(/[^[:word:]]/, " ")
    touch_search(user_id: user.id, query: terms)
    create_search(user_id: user.id, query: terms)
    trim_searches(user_id: user.id)
    redirect("/searches?q=#{url_encode(terms)}")
  end

  # TrackedRoomVisit#default_room: Current.user.rooms.original (order(:created_at).first).
  query :original_room_id, args: { user_id: :i64 }, returns: :i64?, sql: <<~SQL
    SELECT r.id FROM rooms r JOIN memberships m ON m.room_id = r.id WHERE m.user_id = :user_id ORDER BY r.created_at LIMIT 1
  SQL

  # Campfire's `q.gsub(/[^[:word:]]/, " ")`: [[:word:]] keeps Unicode word characters ("café" stays whole).
  get "/searches", params: :SearchParams, cache: :private, description: "Messages in your rooms that match q, newest 100, oldest first" do
    user = current(:user)
    raw = params[:q] || ""
    terms = raw.gsub(/[^[:word:]]/, " ")
    found = terms.strip.empty? ? no_messages() : search_messages(user_id: user.id, q: terms)
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    visited = room_for_user(id: cookie(:last_room, signed: false).to_s.to_i, user_id: user.id)
    recents = recent_searches(user_id: user.id)
    return_to = visited.nil? ? (original_room_id(user_id: user.id) || 0) : visited.id
    body_class = "sidebar searches#{flags.admin == 1 ? " admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    render :searches, locals: { title: "Search", body_class: body_class, logo_version: account_logo_version || "", vapid_key: setting(:vapid_public_key), has_query: !terms.strip.empty?, terms: terms, raw_q: raw, has_raw: raw != "", count: found.length, recents: recents, has_recents: !recents.empty?, return_to: return_to, base_url: request_base_url, messages: found, signed_in: true, user_id: user.id.to_s, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "" }
  end
end
