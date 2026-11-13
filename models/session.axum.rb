model :Session, table: :sessions do
  # app/models/session.rb
  belongs_to :user, model: :User

  execute :start_session, args: { token: :string, user_id: :i64, ip: :string, agent: :string } do
    insert(user_id: arg(:user_id), token: arg(:token), user_agent: arg(:agent), ip_address: arg(:ip), last_active_at: expr(:now))
  end

  execute :end_session, args: { token: :string } do
    where(token: arg(:token)).delete
  end

  # User#deactivate's sessions (see deactivate_user_memberships).
  execute :deactivate_user_sessions, args: { id: :i64 } do
    where(user_id: arg(:id)).delete
  end

  execute :delete_user_sessions, args: { user_id: :i64 } do
    where(user_id: arg(:user_id)).delete
  end

  # Active Storage's direct-upload endpoints, which Campfire's own UI never uses (attachments go through the message
  # post) and config/initializers/active_storage_authentication.rb guards: `head :unauthorized unless
  # find_session_by_cookie` (ActiveStorageAuthentication).
  query :session_for_cookie, args: { token: :string }, returns: :i64? do
    where(token: arg(:token)).pick(:id)
  end

  # require_unauthenticated_access (new, create): restore_authentication, then redirect_signed_in_user_to_root.
  query :signed_in_user_id, args: { token: :string }, returns: :i64? do
    joins(:user).where(token: arg(:token), user: { status: 0 }).pick(:user_id)
  end
end
