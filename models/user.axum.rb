fragment do
  # --- rows -----------------------------------------------------------------------------------------------------

  record :User do
    field :id, :i64
    field :name, :string
    field :password_digest, :string
  end

  # --- sessions (app/controllers/sessions_controller.rb, concerns/authentication.rb) ------------------------------

  # User.active.authenticate_by: status 0 is `active` (app/models/user.rb: enum :status, %i[ active deactivated banned ]).
  query :active_user_by_email, args: { email: :string }, returns: :User?, sql: <<~SQL
    SELECT id, name, COALESCE(password_digest, '') AS password_digest
    FROM users WHERE email_address = :email AND status = 0
  SQL

  query :user_for_session, args: { token: :string }, returns: :User?, sql: <<~SQL
    SELECT users.id AS id, users.name AS name, COALESCE(users.password_digest, '') AS password_digest
    FROM users JOIN sessions ON sessions.user_id = users.id
    WHERE sessions.token = :token AND users.status = 0
  SQL
end
