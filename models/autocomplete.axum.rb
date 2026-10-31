fragment do
  # Autocompletable::UsersController#index: active users whose name matches `pattern`, in Rails'
  # `LOWER(name)` order, 20 at a time. `room_id` narrows the scope to one room the current user is in.
  record :AutocompleteUser do
    field :id, :i64
    field :name, :string
    field :title, :string
    field :avatar_version, :string
  end

  query :autocomplete_all_users, args: { pattern: :string }, returns: list(:AutocompleteUser), sql: <<~SQL
    SELECT u.id AS id, u.name AS name,
           COALESCE(CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END, '') AS title,
           COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS avatar_version
    FROM users u
    WHERE u.status = 0 AND u.name LIKE :pattern
    ORDER BY LOWER(u.name) LIMIT 20
  SQL

  query :autocomplete_room_users, args: { user_id: :i64, room_id: :i64, pattern: :string }, returns: list(:AutocompleteUser), sql: <<~SQL
    SELECT u.id AS id, u.name AS name,
           COALESCE(CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END, '') AS title,
           COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS avatar_version
    FROM users u
    JOIN memberships m ON m.room_id = :room_id AND m.user_id = u.id
    WHERE EXISTS (SELECT 1 FROM memberships me WHERE me.room_id = :room_id AND me.user_id = :user_id)
      AND u.status = 0 AND u.name LIKE :pattern
    ORDER BY LOWER(u.name) LIMIT 20
  SQL
end
