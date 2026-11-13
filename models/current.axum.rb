model do
  # Current.user, read in a route or a filter as `current_user` (Rails' helper): the user of the signed session_token
  # cookie, or nil; behind `before :authenticate` a route reads it non-nil.
  current :user, returns: :User?, required: :authenticate, reader: :current_user do
    token = cookie(:session_token)
    token.nil? ? nil : user_for_session(token: token)
  end

  # The signed-in user's layout flags (administrator, logo, title, version), read once per request as `current_flags`; nil
  # only when the user row is gone, which fails the request as `raise` does. Not for another user (a bot): body_flags is the query for those.
  current :flags, returns: :BodyFlags, reader: :current_flags, missing: "the user was not read back" do
    user = current(:user)
    user.nil? ? nil : body_flags(user_id: user.id)
  end
end
