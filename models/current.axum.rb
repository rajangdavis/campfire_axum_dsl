fragment do
  current :user, returns: :User?, required: :authenticate do
    token = cookie(:session_token)
    token.nil? ? nil : user_for_session(token: token)
  end
end
