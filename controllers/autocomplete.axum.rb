fragment do
  # Rails' `params[:filter].presence || params[:query].presence`: the editor sends `filter`, the
  # autocomplete input sends `query`; an absent optional is empty.
  helper :autocomplete_term, args: [:string?, :string?], returns: :string do |filter, query|
    text = filter.to_s
    text.empty? ? query.to_s : text
  end

  # Autocompletable::UsersController#index, HTML: the <lexxy-prompt-item> list a mentions prompt reads.
  # `filter` is the editor's prompt parameter, `query` the autocomplete input's; both are optional.
  get "/autocompletable/users", params: :AutocompleteParams, description: "Users whose names match a mention query" do
    user = current(:user)
    term = autocomplete_term(params[:filter], params[:query])
    pattern = "%#{term}%"
    room = params[:room_id]
    users = room.nil? ? autocomplete_all_users(pattern: pattern) : autocomplete_room_users(user_id: user.id, room_id: room, pattern: pattern)
    render :autocomplete_users, layout: nil, locals: { users: users }
  end

  # The same list as JSON: name, integer value, fresh avatar URL and the attachable signed GlobalID.
  get "/autocompletable/users.json", params: :AutocompleteParams, description: "Users whose names match a mention query, as JSON" do
    user = current(:user)
    term = autocomplete_term(params[:filter], params[:query])
    pattern = "%#{term}%"
    room = params[:room_id]
    users = room.nil? ? autocomplete_all_users(pattern: pattern) : autocomplete_room_users(user_id: user.id, room_id: room, pattern: pattern)
    items = users.map { |u|
      json_object("name" => u.name,
                  "value" => u.id,
                  "avatar_url" => "#{request_base_url}/users/#{rails_signed_id_for(u.id, purpose: "user/avatar", secret: :secret_key)}/avatar?v=#{u.avatar_version}",
                  "sgid" => rails_signed_global_id("User", u.id, app: "campfire", secret: :secret_key))
    }
    text(json_array(items), content_type: "application/json; charset=utf-8")
  end
end
