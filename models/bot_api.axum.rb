fragment do
  # A message as the bot API draws it (messages/_message.json.jbuilder): created_at is `created_at.utc` as JSON writes it
  # (ISO 8601, three fractional digits, cut not rounded), body the stored Action Text HTML, filename the attachment's
  # (Message#plain_text_body falls back to it), creator_role the User role enum's name and avatar_version the user's
  # updated_at.to_fs(:number) (fresh_user_avatar_url).
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

  # @room.messages.find(id): the id of a message of this room, or nothing (the controller answers 404).
  query :room_message_id, args: { room_id: :i64, id: :i64 }, returns: :i64?, sql: <<~SQL
    SELECT id FROM messages WHERE id = :id AND room_id = :room_id
  SQL

  # find_paged_messages (messages_controller.rb): the last 40 of the room, or of those created before :before (0 for none),
  # oldest to newest.
  query :bot_messages_last, args: { room_id: :i64, before: :i64 }, returns: list(:BotMessage), sql: <<~SQL
    SELECT id, created_at, body, filename, creator_id, creator_name, creator_role, avatar_version, room_id FROM (
      SELECT m.id AS id, m.created_at AS sort_at,
             strftime('%Y-%m-%dT%H:%M:%S', m.created_at) || '.' || CASE WHEN length(m.created_at) >= 23 THEN substr(m.created_at, 21, 3) ELSE '000' END || 'Z' AS created_at,
             COALESCE(t.body, '') AS body,
             COALESCE((SELECT b.filename FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id = a.blob_id
                       WHERE a.record_type = 'Message' AND a.record_id = m.id AND a.name = 'attachment' LIMIT 1), '') AS filename,
             m.creator_id AS creator_id, COALESCE(u.name, '') AS creator_name,
             CASE COALESCE(u.role, 0) WHEN 1 THEN 'administrator' WHEN 2 THEN 'bot' ELSE 'member' END AS creator_role,
             COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS avatar_version, m.room_id AS room_id
      FROM messages m
      LEFT JOIN users u ON u.id = m.creator_id
      LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
      WHERE m.room_id = :room_id
        AND (:before = 0 OR m.created_at < (SELECT a.created_at FROM messages a WHERE a.id = :before AND a.room_id = :room_id))
      ORDER BY m.created_at DESC, m.id DESC LIMIT 40
    ) ORDER BY sort_at ASC, id ASC
  SQL

  # page_after(message): the first 40 messages created after :after.
  query :bot_messages_after, args: { room_id: :i64, after: :i64 }, returns: list(:BotMessage), sql: <<~SQL
    SELECT id, created_at, body, filename, creator_id, creator_name, creator_role, avatar_version, room_id FROM (
      SELECT m.id AS id, m.created_at AS sort_at,
             strftime('%Y-%m-%dT%H:%M:%S', m.created_at) || '.' || CASE WHEN length(m.created_at) >= 23 THEN substr(m.created_at, 21, 3) ELSE '000' END || 'Z' AS created_at,
             COALESCE(t.body, '') AS body,
             COALESCE((SELECT b.filename FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id = a.blob_id
                       WHERE a.record_type = 'Message' AND a.record_id = m.id AND a.name = 'attachment' LIMIT 1), '') AS filename,
             m.creator_id AS creator_id, COALESCE(u.name, '') AS creator_name,
             CASE COALESCE(u.role, 0) WHEN 1 THEN 'administrator' WHEN 2 THEN 'bot' ELSE 'member' END AS creator_role,
             COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS avatar_version, m.room_id AS room_id
      FROM messages m
      LEFT JOIN users u ON u.id = m.creator_id
      LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
      WHERE m.room_id = :room_id
        AND m.created_at > (SELECT a.created_at FROM messages a WHERE a.id = :after AND a.room_id = :room_id)
      ORDER BY m.created_at ASC, m.id ASC LIMIT 40
    ) ORDER BY sort_at ASC, id ASC
  SQL

  # One message of the room, as above.
  query :bot_message, args: { room_id: :i64, id: :i64 }, returns: :BotMessage?, sql: <<~SQL
    SELECT m.id AS id,
           strftime('%Y-%m-%dT%H:%M:%S', m.created_at) || '.' || CASE WHEN length(m.created_at) >= 23 THEN substr(m.created_at, 21, 3) ELSE '000' END || 'Z' AS created_at,
           COALESCE(t.body, '') AS body,
           COALESCE((SELECT b.filename FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id = a.blob_id
                     WHERE a.record_type = 'Message' AND a.record_id = m.id AND a.name = 'attachment' LIMIT 1), '') AS filename,
           m.creator_id AS creator_id, COALESCE(u.name, '') AS creator_name,
           CASE COALESCE(u.role, 0) WHEN 1 THEN 'administrator' WHEN 2 THEN 'bot' ELSE 'member' END AS creator_role,
           COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS avatar_version, m.room_id AS room_id
    FROM messages m
    LEFT JOIN users u ON u.id = m.creator_id
    LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
    WHERE m.id = :id AND m.room_id = :room_id
  SQL

  # set_pagination_headers (by_bots_controller.rb): X-Total-Count is @room.messages.count.
  query :room_message_count, args: { room_id: :i64 }, returns: :i64, sql: <<~SQL
    SELECT COUNT(*) FROM messages WHERE room_id = :room_id
  SQL

  # next_page_params: `@room.messages.before(first).exists?` and `.after(last).exists?`, as 0 or 1.
  query :bot_older_exists, args: { room_id: :i64, id: :i64 }, returns: :i64, sql: <<~SQL
    SELECT EXISTS (SELECT 1 FROM messages m JOIN messages a ON a.id = :id WHERE m.room_id = :room_id AND m.created_at < a.created_at)
  SQL

  query :bot_newer_exists, args: { room_id: :i64, id: :i64 }, returns: :i64, sql: <<~SQL
    SELECT EXISTS (SELECT 1 FROM messages m JOIN messages a ON a.id = :id WHERE m.room_id = :room_id AND m.created_at > a.created_at)
  SQL

  # MessagesController#update: `@message.update!(body:)` saves the Action Text row (the body is its own row, so an
  # upsert on its unique index), which touches the message and, through it, the room (belongs_to :record/:room, touch: true).
  execute :save_message_body, args: { message_id: :i64, body: :string }, sql: <<~SQL
    INSERT INTO action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at)
    VALUES ('Message', :message_id, 'body', :body, strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now'))
    ON CONFLICT (record_type, record_id, name) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at
  SQL

  execute :touch_message, args: { message_id: :i64 }, sql: <<~SQL
    UPDATE messages SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = :message_id
  SQL

  execute :touch_message_room, args: { message_id: :i64 }, sql: <<~SQL
    UPDATE rooms SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = (SELECT room_id FROM messages WHERE id = :message_id)
  SQL

  # Message::Searchable#update_in_index: the FTS row's body is the message's plain text.
  execute :reindex_message, args: { message_id: :i64, body: :string }, sql: <<~SQL
    UPDATE message_search_index SET body = :body WHERE rowid = :message_id
  SQL

  # Messages::Boosts::ByBotsController#create: `@message.boosts.create!(content:)`, which touches the message.
  query :create_boost, args: { message_id: :i64, booster_id: :i64, content: :string }, returns: :i64, sql: <<~SQL
    INSERT INTO boosts (message_id, booster_id, content, created_at, updated_at)
    VALUES (:message_id, :booster_id, :content, strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now'))
    RETURNING id
  SQL

  query :bot_boost, args: { id: :i64 }, returns: :BotBoost?, sql: <<~SQL
    SELECT b.id AS id, b.content AS content,
           strftime('%Y-%m-%dT%H:%M:%S', b.created_at) || '.' || CASE WHEN length(b.created_at) >= 23 THEN substr(b.created_at, 21, 3) ELSE '000' END || 'Z' AS created_at,
           b.booster_id AS booster_id, COALESCE(u.name, '') AS booster_name,
           CASE COALESCE(u.role, 0) WHEN 1 THEN 'administrator' WHEN 2 THEN 'bot' ELSE 'member' END AS booster_role,
           COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS avatar_version,
           m.room_id AS room_id, m.id AS message_id
    FROM boosts b
    JOIN messages m ON m.id = b.message_id
    LEFT JOIN users u ON u.id = b.booster_id
    WHERE b.id = :id
  SQL
end
