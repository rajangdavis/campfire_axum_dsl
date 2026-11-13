model do
  # A message as the bot API draws it (messages/_message.json.jbuilder): created_at is `created_at.utc` as JSON writes it
  # (ISO 8601, three fractional digits, cut not rounded), body the stored Action Text HTML, filename the attachment's
  # (Message#plain_text_body falls back to it), creator_role the User role enum's name and avatar_version the user's
  # updated_at.to_fs(:number) (fresh_user_avatar_url). The queries are in models/message.axum.rb (bot_messages_last,
  # bot_messages_after, bot_message).
  record :BotMessage do
    field :id, :i64
    field :created_at, :string
    field :body, :string
    field :filename, :string
    field :creator_id, :i64
    field :creator_name, :string
    field :creator_role, :string
    field :avatar_version, :string
    field :room_id, :i64
  end

  # messages/boosts/_boost.json.jbuilder: the boost, its booster as users/_user.json draws them, and its message's url parts.
  # The query (bot_boost) is in models/boost.axum.rb.
  record :BotBoost do
    field :id, :i64
    field :content, :string
    field :created_at, :string
    field :booster_id, :i64
    field :booster_name, :string
    field :booster_role, :string
    field :avatar_version, :string
    field :room_id, :i64
    field :message_id, :i64
  end

  # User.authenticate_bot (models/user/bot.rb) behind Authentication#require_authentication: the session's user first
  # (restore_authentication), else the active bot a "<id>-<bot_token>" key names (`bot_key.split("-")`: the first two
  # parts). A key with no "-" names nobody. Role 2 is `bot` (user/role.rb), status 0 `active`.
  query :bot_actor, args: { token: :string, key: :string }, returns: :User?, sql: <<~SQL
    WITH k AS (
      SELECT CAST(substr(:key, 1, instr(:key, '-') - 1) AS INTEGER) AS bot_id,
             substr(:key, instr(:key, '-') + 1) AS rest
      WHERE instr(:key, '-') > 0
    ), p AS (
      SELECT bot_id, CASE WHEN instr(rest, '-') > 0 THEN substr(rest, 1, instr(rest, '-') - 1) ELSE rest END AS bot_token FROM k
    )
    SELECT u.id AS id, u.name AS name, COALESCE(u.password_digest, '') AS password_digest
    FROM users u
    WHERE u.status = 0 AND (
      u.id = (SELECT s.user_id FROM sessions s WHERE s.token = :token)
      OR (u.role = 2 AND EXISTS (SELECT 1 FROM p WHERE p.bot_id = u.id AND p.bot_token = u.bot_token)))
    ORDER BY CASE WHEN u.id = (SELECT s.user_id FROM sessions s WHERE s.token = :token) THEN 0 ELSE 1 END
    LIMIT 1
  SQL

  # MessagesController#update: `@message.update!(body:)` saves the Action Text row (the body is its own row, so an
  # upsert on its unique index), which touches the message and, through it, the room (belongs_to :record/:room, touch: true).
  execute :save_message_body, args: { message_id: :i64, body: :string }, sql: <<~SQL
    INSERT INTO action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at)
    VALUES ('Message', :message_id, 'body', :body, strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now'))
    ON CONFLICT (record_type, record_id, name) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at
  SQL
end
