fragment do
  # A message with its creator's name and its body (the action_text_rich_texts row; '' when there is none).
  record :MessageRow do
    field :id, :i64
    field :creator_name, :string
    field :created_at, :string
    field :body, :string
  end

  # Message.ordered.last(40): the newest 40 by created_at, handed back oldest to newest.
  query :last_page, args: { room_id: :i64 }, returns: list(:MessageRow), sql: <<~SQL
    SELECT id, creator_name, created_at, body FROM (
      SELECT m.id AS id, u.name AS creator_name, m.created_at AS created_at, COALESCE(t.body, '') AS body
      FROM messages m
      JOIN users u ON u.id = m.creator_id
      LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
      WHERE m.room_id = :room_id
      ORDER BY m.created_at DESC, m.id DESC LIMIT 40
    ) ORDER BY created_at ASC, id ASC
  SQL

  # page_before(message): the 40 messages created before :before (a message of this room), oldest to newest.
  query :messages_before, args: { room_id: :i64, before: :i64 }, returns: list(:MessageRow), sql: <<~SQL
    SELECT id, creator_name, created_at, body FROM (
      SELECT m.id AS id, u.name AS creator_name, m.created_at AS created_at, COALESCE(t.body, '') AS body
      FROM messages m
      JOIN messages a ON a.id = :before AND a.room_id = m.room_id
      JOIN users u ON u.id = m.creator_id
      LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
      WHERE m.room_id = :room_id AND m.created_at < a.created_at
      ORDER BY m.created_at DESC, m.id DESC LIMIT 40
    ) ORDER BY created_at ASC, id ASC
  SQL

  # --- search (searches_controller.rb, message/searchable.rb): Current.user.reachable_messages.search(q).last(100) ----

  query :search_messages, args: { user_id: :i64, q: :string }, returns: list(:MessageRow), sql: <<~SQL
    SELECT id, creator_name, created_at, body FROM (
      SELECT m.id AS id, u.name AS creator_name, m.created_at AS created_at, COALESCE(t.body, '') AS body
      FROM messages m
      JOIN message_search_index idx ON idx.rowid = m.id
      JOIN users u ON u.id = m.creator_id
      LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
      WHERE m.room_id IN (SELECT room_id FROM memberships WHERE user_id = :user_id) AND idx.body MATCH :q
      ORDER BY m.id DESC LIMIT 100
    ) ORDER BY id ASC
  SQL

  # Message.none, for a blank query (FTS5 refuses an empty MATCH).
  query :no_messages, args: {}, returns: list(:MessageRow), sql: <<~SQL
    SELECT 0 AS id, '' AS creator_name, '' AS created_at, '' AS body WHERE 0
  SQL

  # Rails' Message#create!: the id comes from RETURNING, not last_insert_rowid(), because the pool may hand the
  # next statement a different connection. The INSERT always yields one row, so a no-row result is a DB error
  # (which rolls the transaction back); inside the transaction the id is therefore non-nil.
  query :create_message, args: { room_id: :i64, creator_id: :i64, client_message_id: :string }, returns: :i64, sql: <<~SQL
    INSERT INTO messages (client_message_id, room_id, creator_id, created_at, updated_at)
    VALUES (:client_message_id, :room_id, :creator_id,
            strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now'))
    RETURNING id
  SQL

  # has_rich_text :body: the one Action Text row, named body, for the new message.
  execute :create_message_body, args: { message_id: :i64, body: :string }, sql: <<~SQL
    INSERT INTO action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at)
    VALUES ('Message', :message_id, 'body', :body,
            strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now'))
  SQL

  # Message.searchable: the plain text, with the message id as the FTS5 rowid.
  execute :index_message, args: { message_id: :i64, body: :string }, sql: <<~SQL
    INSERT INTO message_search_index (rowid, body) VALUES (:message_id, :body)
  SQL

  # The new row as the page reads it: creator_name and created_at come from the database, not from bind values.
  query :message_row, args: { id: :i64 }, returns: :MessageRow?, sql: <<~SQL
    SELECT m.id AS id, u.name AS creator_name, m.created_at AS created_at, COALESCE(t.body, '') AS body
    FROM messages m
    JOIN users u ON u.id = m.creator_id
    LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
    WHERE m.id = :id
  SQL
end
