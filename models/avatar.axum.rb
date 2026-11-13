model do
  # --- avatars (app/controllers/users/avatars_controller.rb, app/models/user/avatar.rb) ---------------------------

  # The user's avatar blob, the source of Rails' avatar_variant (`avatar.variant(:square).processed if avatar.variable?`):
  # its :square variant is made on the first request that asks for it (models/variant.axum.rb).
  record :AvatarSource do
    field :key, :string
    field :filename, :string
    field :content_type, :string, optional: true
  end

  # Users::AvatarsController#show when the variant is absent: User#name, User#initials and User#bot? (role 2),

  # plus the cache-key version `stale?(etag: @user)` derives. initials is `name.scan(/\b\w/).join`: the
  # recursive CTE walks the name's characters and keeps each word's first ASCII word character in order.
  # Ruby's `\w` is ASCII-only, so a leading Unicode letter is not reproduced; the seed names are ASCII.
  record :AvatarFallback do
    field :name, :string
    field :initials, :string
    field :bot, :bool
    field :version, :string
  end

  query :avatar_fallback, args: { user_id: :i64 }, returns: :AvatarFallback?, sql: <<~SQL
    WITH RECURSIVE
    user_row(id, name, role, updated_at) AS (
      SELECT id, name, role, updated_at FROM users WHERE id = :user_id
    ),
    positions(i) AS (
      SELECT 1
      UNION ALL
      SELECT i + 1 FROM positions WHERE i < (SELECT length(name) FROM user_row)
    ),
    initials AS (
      SELECT group_concat(ch, '') AS value FROM (
        SELECT substr(u.name, p.i, 1) AS ch
        FROM user_row u JOIN positions p ON p.i <= length(u.name)
        WHERE instr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_', substr(u.name, p.i, 1)) > 0
          AND (p.i = 1 OR instr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_', substr(u.name, p.i - 1, 1)) = 0)
        ORDER BY p.i
      )
    )
    SELECT u.name AS name, COALESCE(i.value, '') AS initials,
           CASE WHEN u.role = 2 THEN 1 ELSE 0 END AS bot,
           strftime('%Y%m%d%H%M%S', u.updated_at) AS version
    FROM user_row u, initials i
  SQL
  # The avatar's attachment statements (attach_user_avatar ...) are derived by `has_one_attached :avatar` in models/user.axum.rb.
end
