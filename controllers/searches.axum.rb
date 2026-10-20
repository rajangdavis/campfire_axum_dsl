fragment do
  # Campfire's `q.gsub(/[^[:word:]]/, " ")`: [[:word:]] keeps Unicode word characters ("café" stays whole).
  get "/searches", params: :SearchParams, description: "Messages in your rooms that match q, newest 100, oldest first" do
    user = current(:user)
    terms = (params[:q] || "").gsub(/[^[:word:]]/, " ")
    found = terms.strip.empty? ? no_messages() : search_messages(user_id: user.id, q: terms)
    render :searches, locals: { title: "Search", terms: terms, messages: found }
  end
end
