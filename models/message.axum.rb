fragment do
  # A message as the room page, the search page and the message streams render it (messages/_message): who wrote it
  # (creator_title is User#title, avatar_version the user's updated_at.to_fs(:number)), when (the epoch-millisecond
  # and ISO 8601 spellings Rails writes into data attributes), where (room_label is room_display_name(room, for_user:
  # nil)) and its body (the action_text_rich_texts row; '' when there is none).
  record :MessageRow do
    field :id, :i64
    field :param, :string
    field :creator_id, :i64
    field :creator_name, :string
    field :creator_title, :string
    field :avatar_version, :string
    field :created_at, :string
    field :created_ms, :i64
    field :updated_ms, :i64
    field :created_iso, :string
    field :room_id, :i64
    field :renderable, :bool
    field :room_label, :string
    field :body, :string
    # messages/_boosts: each message's boosts, one message_boosts query per row (its `id` argument is this row's id).
    field :boosts, list(:BoostRow), from: :message_boosts
    # messages/_presentation: what the message shows in place of a text body (one row, always).
    field :presentation, list(:PresentationRow), from: :message_presentation
    # Action Text mentions in the body, one row per distinct user the body's attachments name.
    field :mentions, list(:MentionRow), from: :message_mentions
  end

  # messages/_presentation and Messages::AttachmentPresentation: a text message, or its attachment drawn as an image
  # (variable: Active Storage's variable_content_types), a video (previewable) or a file link. The sizes are
  # preview_dimensions in the spelling Ruby gives them: an Integer stays "640", a Float is "1200.0", and the aspect
  # ratio is the shortest round-trip Float#to_s. `format` is the variation's format (a video's poster is webp).
  record :PresentationRow do
    field :is_text, :bool
    field :is_image, :bool
    field :is_video, :bool
    field :is_file, :bool
    field :blob_id, :i64
    field :filename, :string
    field :filename_path, :string
    field :format, :string
    field :has_dims, :bool
    field :box_width, :string
    field :aspect, :string
    field :width, :string
    field :height, :string
  end

  # The users a body's mention attachments name (UserMentionable via the attachable sgid): the fields avatar_tag and
  # users/_mention read.
  record :MentionRow do
    field :id, :i64
    field :name, :string
    field :title, :string
    field :version, :string
  end

  # `action_text_attachable_ids(body, 'User')` is the DSL's SQL function over the body's <action-text-attachment sgid>s
  # (a JSON array of the User ids their GlobalIDs name; a Rails 7 Marshal-era sgid counts, as
  # lib/rails_ext/action_text_attachables.rb tolerates it for users).
  query :message_mentions, args: { body: :string }, returns: list(:MentionRow), sql: <<~SQL
    SELECT u.id AS id, u.name AS name,
           CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END AS title,
           COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS version
    FROM users u
    WHERE u.id IN (SELECT value FROM json_each(action_text_attachable_ids(:body, 'User')))
    ORDER BY u.id
  SQL

  query :message_presentation, args: { id: :i64 }, returns: list(:PresentationRow), sql: <<~SQL
    WITH att AS (
      SELECT b.id AS blob_id, b.filename AS filename, b.content_type AS content_type,
             json_extract(b.metadata, '$.width') AS w, json_extract(b.metadata, '$.height') AS h
      FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id = a.blob_id
      WHERE a.record_type = 'Message' AND a.record_id = :id AND a.name = 'attachment' LIMIT 1
    ),
    k AS (
      SELECT att.*, CASE WHEN att.blob_id IS NULL THEN 'text'
                         WHEN att.content_type LIKE 'video/%' THEN 'video'
                         WHEN att.content_type IN ('image/png', 'image/jpeg', 'image/jpg', 'image/gif', 'image/vnd.adobe.photoshop', 'image/vnd.microsoft.icon', 'image/webp', 'image/avif', 'image/heic', 'image/heif') THEN 'image'
                         ELSE 'file' END AS kind
      FROM (SELECT 1) LEFT JOIN att
    ),
    s AS (
      SELECT k.*, CASE WHEN kind IN ('image', 'video') AND w IS NOT NULL AND h IS NOT NULL THEN 1 ELSE 0 END AS has_dims,
             CASE WHEN w IS NOT NULL AND h IS NOT NULL AND (w > 1200 OR h > 800) THEN 1 ELSE 0 END AS scaled,
             MIN(1200.0 / w, 800.0 / h) AS f
      FROM k
    ),
    d AS (
      SELECT s.*, CASE WHEN scaled THEN w * f ELSE w END AS dw, CASE WHEN scaled THEN h * f ELSE h END AS dh FROM s
    ),
    r AS (
      SELECT d.*, dw / 2.0 AS r_box, dw * 1.0 / dh AS r_aspect, dw * 1.0 AS r_w, dh * 1.0 AS r_h FROM d
    )
    SELECT kind = 'text' AS is_text, kind = 'image' AS is_image, kind = 'video' AS is_video, kind = 'file' AS is_file,
           COALESCE(blob_id, 0) AS blob_id, COALESCE(filename, '') AS filename,
           COALESCE(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(filename, '%', '%25'), ' ', '%20'), '"', '%22'), '#', '%23'), '&', '%26'), '+', '%2B'), ',', '%2C'), '/', '%2F'), ':', '%3A'), ';', '%3B'), '=', '%3D'), '?', '%3F'), '@', '%40'), '') AS filename_path,
           CASE WHEN kind = 'video' THEN 'webp'
                WHEN content_type = 'image/png' THEN 'png' WHEN content_type = 'image/gif' THEN 'gif' WHEN content_type = 'image/webp' THEN 'webp'
                WHEN content_type = 'image/avif' THEN 'avif' ELSE 'jpg' END AS format,
           has_dims,
           CASE WHEN NOT has_dims THEN '' WHEN typeof(dw) = 'integer' THEN CAST(dw / 2 AS TEXT)
                WHEN CAST(printf('%!.15g', r_box) AS REAL) = r_box THEN printf('%!.15g', r_box)
                WHEN CAST(printf('%!.16g', r_box) AS REAL) = r_box THEN printf('%!.16g', r_box)
                ELSE printf('%!.17g', r_box) END AS box_width,
           CASE WHEN NOT has_dims THEN ''
                WHEN CAST(printf('%!.15g', r_aspect) AS REAL) = r_aspect THEN printf('%!.15g', r_aspect)
                WHEN CAST(printf('%!.16g', r_aspect) AS REAL) = r_aspect THEN printf('%!.16g', r_aspect)
                ELSE printf('%!.17g', r_aspect) END AS aspect,
           CASE WHEN NOT has_dims THEN '' WHEN typeof(dw) = 'integer' THEN CAST(dw AS TEXT)
                WHEN CAST(printf('%!.15g', r_w) AS REAL) = r_w THEN printf('%!.15g', r_w)
                WHEN CAST(printf('%!.16g', r_w) AS REAL) = r_w THEN printf('%!.16g', r_w)
                ELSE printf('%!.17g', r_w) END AS width,
           CASE WHEN NOT has_dims THEN '' WHEN typeof(dh) = 'integer' THEN CAST(dh AS TEXT)
                WHEN CAST(printf('%!.15g', r_h) AS REAL) = r_h THEN printf('%!.15g', r_h)
                WHEN CAST(printf('%!.16g', r_h) AS REAL) = r_h THEN printf('%!.16g', r_h)
                ELSE printf('%!.17g', r_h) END AS height
    FROM r
  SQL

  # messages/_boost: the booster as avatar_tag draws them, and the aria-label "<name> boosted <content>". The view asks
  # String#all_emoji? of the content itself (`{% if boost.content|all_emoji %}`).
  record :BoostRow do
    field :id, :i64
    field :booster_id, :i64
    field :booster_title, :string
    field :booster_version, :string
    field :label, :string
    field :content, :string
  end

  # message.boosts.ordered
  query :message_boosts, args: { id: :i64 }, returns: list(:BoostRow), sql: <<~SQL
    SELECT b.id AS id, b.booster_id AS booster_id,
           CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END AS booster_title,
           COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS booster_version,
           u.name || ' boosted ' || b.content AS label, b.content AS content
    FROM boosts b
    JOIN users u ON u.id = b.booster_id
    WHERE b.message_id = :id
    ORDER BY b.created_at ASC, b.id ASC
  SQL

  # The one boost messages/boosts/_boost draws for a broadcast (message_boosts for a single id).
  query :boost_row, args: { id: :i64 }, returns: :BoostRow?, sql: <<~SQL
    SELECT b.id AS id, b.booster_id AS booster_id,
           CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END AS booster_title,
           COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS booster_version,
           u.name || ' boosted ' || b.content AS label, b.content AS content
    FROM boosts b
    JOIN users u ON u.id = b.booster_id
    WHERE b.id = :id
  SQL

  # Message.ordered.last(40): the newest 40 by created_at, handed back oldest to newest.
  query :last_page, args: { room_id: :i64 }, returns: list(:MessageRow), sql: <<~SQL
    SELECT id, param, creator_id, creator_name, creator_title, avatar_version, created_at, created_ms, updated_ms, created_iso, room_id, renderable, room_label, body FROM (
      SELECT m.id AS id, COALESCE(m.client_message_id, CAST(m.id AS TEXT)) AS param, m.creator_id AS creator_id, COALESCE(u.name, '') AS creator_name,
             COALESCE(CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END, '') AS creator_title,
             COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS avatar_version,
             m.created_at AS created_at,
             CAST(strftime('%s', m.created_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.created_at), 4) AS INTEGER) AS created_ms,
             CAST(strftime('%s', m.updated_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.updated_at), 4) AS INTEGER) AS updated_ms,
             strftime('%Y-%m-%dT%H:%M:%SZ', m.created_at) AS created_iso,
             m.room_id AS room_id, CASE WHEN u.id IS NULL THEN 0 ELSE 1 END AS renderable,
             CASE WHEN r.type = 'Rooms::Direct' THEN COALESCE((SELECT CASE WHEN o.cnt = 1 THEN o.s ELSE substr(o.s, 1, length(o.s) - length(o.last_name) - 2) || CASE o.cnt WHEN 2 THEN ' and ' ELSE ', and ' END || o.last_name END FROM (SELECT COUNT(*) AS cnt, group_concat(n.name, ', ') AS s, (SELECT u2.name FROM memberships m2 JOIN users u2 ON u2.id = m2.user_id WHERE m2.room_id = r.id ORDER BY u2.id DESC LIMIT 1) AS last_name FROM (SELECT u3.name AS name FROM memberships m3 JOIN users u3 ON u3.id = m3.user_id WHERE m3.room_id = r.id ORDER BY u3.id) AS n) AS o WHERE o.cnt > 0), '') ELSE COALESCE(r.name, '') END AS room_label,
             COALESCE(t.body, '') AS body
      FROM messages m
      LEFT JOIN users u ON u.id = m.creator_id
      JOIN rooms r ON r.id = m.room_id
      LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
      WHERE m.room_id = :room_id
      ORDER BY m.created_at DESC, m.id DESC LIMIT 40
    ) ORDER BY created_at ASC, id ASC
  SQL

  # page_before(message): the 40 messages created before :before (a message of this room), oldest to newest.
  query :messages_before, args: { room_id: :i64, before: :i64 }, returns: list(:MessageRow), sql: <<~SQL
    SELECT id, param, creator_id, creator_name, creator_title, avatar_version, created_at, created_ms, updated_ms, created_iso, room_id, renderable, room_label, body FROM (
      SELECT m.id AS id, COALESCE(m.client_message_id, CAST(m.id AS TEXT)) AS param, m.creator_id AS creator_id, COALESCE(u.name, '') AS creator_name,
             COALESCE(CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END, '') AS creator_title,
             COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS avatar_version,
             m.created_at AS created_at,
             CAST(strftime('%s', m.created_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.created_at), 4) AS INTEGER) AS created_ms,
             CAST(strftime('%s', m.updated_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.updated_at), 4) AS INTEGER) AS updated_ms,
             strftime('%Y-%m-%dT%H:%M:%SZ', m.created_at) AS created_iso,
             m.room_id AS room_id, CASE WHEN u.id IS NULL THEN 0 ELSE 1 END AS renderable,
             CASE WHEN r.type = 'Rooms::Direct' THEN COALESCE((SELECT CASE WHEN o.cnt = 1 THEN o.s ELSE substr(o.s, 1, length(o.s) - length(o.last_name) - 2) || CASE o.cnt WHEN 2 THEN ' and ' ELSE ', and ' END || o.last_name END FROM (SELECT COUNT(*) AS cnt, group_concat(n.name, ', ') AS s, (SELECT u2.name FROM memberships m2 JOIN users u2 ON u2.id = m2.user_id WHERE m2.room_id = r.id ORDER BY u2.id DESC LIMIT 1) AS last_name FROM (SELECT u3.name AS name FROM memberships m3 JOIN users u3 ON u3.id = m3.user_id WHERE m3.room_id = r.id ORDER BY u3.id) AS n) AS o WHERE o.cnt > 0), '') ELSE COALESCE(r.name, '') END AS room_label,
             COALESCE(t.body, '') AS body
      FROM messages m
      JOIN messages a ON a.id = :before AND a.room_id = m.room_id
      LEFT JOIN users u ON u.id = m.creator_id
      JOIN rooms r ON r.id = m.room_id
      LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
      WHERE m.room_id = :room_id AND m.created_at < a.created_at
      ORDER BY m.created_at DESC, m.id DESC LIMIT 40
    ) ORDER BY created_at ASC, id ASC
  SQL

  # page_after(message): the 40 messages created after :after (a message of this room), oldest to newest.
  query :messages_after, args: { room_id: :i64, after: :i64 }, returns: list(:MessageRow), sql: <<~SQL
    SELECT m.id AS id, COALESCE(m.client_message_id, CAST(m.id AS TEXT)) AS param, m.creator_id AS creator_id, COALESCE(u.name, '') AS creator_name,
             COALESCE(CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END, '') AS creator_title,
             COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS avatar_version,
             m.created_at AS created_at,
             CAST(strftime('%s', m.created_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.created_at), 4) AS INTEGER) AS created_ms,
             CAST(strftime('%s', m.updated_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.updated_at), 4) AS INTEGER) AS updated_ms,
             strftime('%Y-%m-%dT%H:%M:%SZ', m.created_at) AS created_iso,
             m.room_id AS room_id, CASE WHEN u.id IS NULL THEN 0 ELSE 1 END AS renderable,
             CASE WHEN r.type = 'Rooms::Direct' THEN COALESCE((SELECT CASE WHEN o.cnt = 1 THEN o.s ELSE substr(o.s, 1, length(o.s) - length(o.last_name) - 2) || CASE o.cnt WHEN 2 THEN ' and ' ELSE ', and ' END || o.last_name END FROM (SELECT COUNT(*) AS cnt, group_concat(n.name, ', ') AS s, (SELECT u2.name FROM memberships m2 JOIN users u2 ON u2.id = m2.user_id WHERE m2.room_id = r.id ORDER BY u2.id DESC LIMIT 1) AS last_name FROM (SELECT u3.name AS name FROM memberships m3 JOIN users u3 ON u3.id = m3.user_id WHERE m3.room_id = r.id ORDER BY u3.id) AS n) AS o WHERE o.cnt > 0), '') ELSE COALESCE(r.name, '') END AS room_label,
             COALESCE(t.body, '') AS body
    FROM messages m
    JOIN messages a ON a.id = :after AND a.room_id = m.room_id
    LEFT JOIN users u ON u.id = m.creator_id
      JOIN rooms r ON r.id = m.room_id
      LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
    WHERE m.room_id = :room_id AND m.created_at > a.created_at
    ORDER BY m.created_at ASC, m.id ASC LIMIT 40
  SQL

  # page_around(message): page_before + [message] + page_after (RoomsController#find_messages for /rooms/:id/@:message_id);
  # empty when the message is not in the room, and the page then falls back to the last page.
  query :messages_around, args: { room_id: :i64, around: :i64 }, returns: list(:MessageRow), sql: <<~SQL
    SELECT m.id AS id, COALESCE(m.client_message_id, CAST(m.id AS TEXT)) AS param, m.creator_id AS creator_id, COALESCE(u.name, '') AS creator_name,
             COALESCE(CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END, '') AS creator_title,
             COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS avatar_version,
             m.created_at AS created_at,
             CAST(strftime('%s', m.created_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.created_at), 4) AS INTEGER) AS created_ms,
             CAST(strftime('%s', m.updated_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.updated_at), 4) AS INTEGER) AS updated_ms,
             strftime('%Y-%m-%dT%H:%M:%SZ', m.created_at) AS created_iso,
             m.room_id AS room_id, CASE WHEN u.id IS NULL THEN 0 ELSE 1 END AS renderable,
             CASE WHEN r.type = 'Rooms::Direct' THEN COALESCE((SELECT CASE WHEN o.cnt = 1 THEN o.s ELSE substr(o.s, 1, length(o.s) - length(o.last_name) - 2) || CASE o.cnt WHEN 2 THEN ' and ' ELSE ', and ' END || o.last_name END FROM (SELECT COUNT(*) AS cnt, group_concat(n.name, ', ') AS s, (SELECT u2.name FROM memberships m2 JOIN users u2 ON u2.id = m2.user_id WHERE m2.room_id = r.id ORDER BY u2.id DESC LIMIT 1) AS last_name FROM (SELECT u3.name AS name FROM memberships m3 JOIN users u3 ON u3.id = m3.user_id WHERE m3.room_id = r.id ORDER BY u3.id) AS n) AS o WHERE o.cnt > 0), '') ELSE COALESCE(r.name, '') END AS room_label,
             COALESCE(t.body, '') AS body
    FROM messages m
    JOIN messages a ON a.id = :around AND a.room_id = m.room_id
    LEFT JOIN users u ON u.id = m.creator_id
      JOIN rooms r ON r.id = m.room_id
      LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
    WHERE m.room_id = :room_id AND (
      m.id = a.id
      OR m.id IN (SELECT b.id FROM messages b WHERE b.room_id = a.room_id AND b.created_at < a.created_at ORDER BY b.created_at DESC, b.id DESC LIMIT 40)
      OR m.id IN (SELECT b.id FROM messages b WHERE b.room_id = a.room_id AND b.created_at > a.created_at ORDER BY b.created_at ASC, b.id ASC LIMIT 40))
    ORDER BY m.created_at ASC, m.id ASC
  SQL

  # --- search (searches_controller.rb, message/searchable.rb): Current.user.reachable_messages.search(q).last(100) ----

  query :search_messages, args: { user_id: :i64, q: :string }, returns: list(:MessageRow), sql: <<~SQL
    SELECT id, param, creator_id, creator_name, creator_title, avatar_version, created_at, created_ms, updated_ms, created_iso, room_id, renderable, room_label, body FROM (
      SELECT m.id AS id, COALESCE(m.client_message_id, CAST(m.id AS TEXT)) AS param, m.creator_id AS creator_id, COALESCE(u.name, '') AS creator_name,
             COALESCE(CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END, '') AS creator_title,
             COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS avatar_version,
             m.created_at AS created_at,
             CAST(strftime('%s', m.created_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.created_at), 4) AS INTEGER) AS created_ms,
             CAST(strftime('%s', m.updated_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.updated_at), 4) AS INTEGER) AS updated_ms,
             strftime('%Y-%m-%dT%H:%M:%SZ', m.created_at) AS created_iso,
             m.room_id AS room_id, CASE WHEN u.id IS NULL THEN 0 ELSE 1 END AS renderable,
             CASE WHEN r.type = 'Rooms::Direct' THEN COALESCE((SELECT CASE WHEN o.cnt = 1 THEN o.s ELSE substr(o.s, 1, length(o.s) - length(o.last_name) - 2) || CASE o.cnt WHEN 2 THEN ' and ' ELSE ', and ' END || o.last_name END FROM (SELECT COUNT(*) AS cnt, group_concat(n.name, ', ') AS s, (SELECT u2.name FROM memberships m2 JOIN users u2 ON u2.id = m2.user_id WHERE m2.room_id = r.id ORDER BY u2.id DESC LIMIT 1) AS last_name FROM (SELECT u3.name AS name FROM memberships m3 JOIN users u3 ON u3.id = m3.user_id WHERE m3.room_id = r.id ORDER BY u3.id) AS n) AS o WHERE o.cnt > 0), '') ELSE COALESCE(r.name, '') END AS room_label,
             COALESCE(t.body, '') AS body
      FROM messages m
      JOIN message_search_index idx ON idx.rowid = m.id
      LEFT JOIN users u ON u.id = m.creator_id
      JOIN rooms r ON r.id = m.room_id
      LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
      WHERE m.room_id IN (SELECT room_id FROM memberships WHERE user_id = :user_id) AND idx.body MATCH :q
      ORDER BY m.id DESC LIMIT 100
    ) ORDER BY id ASC
  SQL

  # Message.none, for a blank query (FTS5 refuses an empty MATCH).
  query :no_messages, args: {}, returns: list(:MessageRow), sql: <<~SQL
    SELECT 0 AS id, '' AS param, 0 AS creator_id, '' AS creator_name, '' AS creator_title, '' AS avatar_version, '' AS created_at,
           0 AS created_ms, 0 AS updated_ms, '' AS created_iso, 0 AS room_id, 0 AS renderable, '' AS room_label, '' AS body WHERE 0
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

  # has_rich_text :body: the one Action Text row, named body, for the new message. A message created with an attachment
  # and no body (the composer's file post sends none) gets no row, as in Rails, where the row exists only once a body
  # is assigned.
  execute :create_message_body, args: { message_id: :i64, body: :string }, sql: <<~SQL
    INSERT INTO action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at)
    SELECT 'Message', :message_id, 'body', :body,
           strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE :body <> ''
  SQL

  # has_one_attached :attachment (Message::Attachment): the attachment row tying a blob (models/avatar.axum.rb insert_blob)
  # to the message by the blob's key; it does nothing for the key "" (the message has no file).
  execute :attach_message_file, args: { message_id: :i64, key: :string }, sql: <<~SQL
    INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at)
    SELECT 'attachment', 'Message', :message_id, b.id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM active_storage_blobs b WHERE b.key = :key AND :key <> ''
  SQL

  # Message.searchable: the plain text, with the message id as the FTS5 rowid.
  execute :index_message, args: { message_id: :i64, body: :string }, sql: <<~SQL
    INSERT INTO message_search_index (rowid, body) VALUES (:message_id, :body)
  SQL

  # The new row as the page reads it: creator_name and created_at come from the database, not from bind values.
  query :message_row, args: { id: :i64 }, returns: :MessageRow?, sql: <<~SQL
    SELECT m.id AS id, COALESCE(m.client_message_id, CAST(m.id AS TEXT)) AS param, m.creator_id AS creator_id, COALESCE(u.name, '') AS creator_name,
             COALESCE(CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END, '') AS creator_title,
             COALESCE(strftime('%Y%m%d%H%M%S', u.updated_at), '') AS avatar_version,
             m.created_at AS created_at,
             CAST(strftime('%s', m.created_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.created_at), 4) AS INTEGER) AS created_ms,
             CAST(strftime('%s', m.updated_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', m.updated_at), 4) AS INTEGER) AS updated_ms,
             strftime('%Y-%m-%dT%H:%M:%SZ', m.created_at) AS created_iso,
             m.room_id AS room_id, CASE WHEN u.id IS NULL THEN 0 ELSE 1 END AS renderable,
             CASE WHEN r.type = 'Rooms::Direct' THEN COALESCE((SELECT CASE WHEN o.cnt = 1 THEN o.s ELSE substr(o.s, 1, length(o.s) - length(o.last_name) - 2) || CASE o.cnt WHEN 2 THEN ' and ' ELSE ', and ' END || o.last_name END FROM (SELECT COUNT(*) AS cnt, group_concat(n.name, ', ') AS s, (SELECT u2.name FROM memberships m2 JOIN users u2 ON u2.id = m2.user_id WHERE m2.room_id = r.id ORDER BY u2.id DESC LIMIT 1) AS last_name FROM (SELECT u3.name AS name FROM memberships m3 JOIN users u3 ON u3.id = m3.user_id WHERE m3.room_id = r.id ORDER BY u3.id) AS n) AS o WHERE o.cnt > 0), '') ELSE COALESCE(r.name, '') END AS room_label,
             COALESCE(t.body, '') AS body
    FROM messages m
    LEFT JOIN users u ON u.id = m.creator_id
      JOIN rooms r ON r.id = m.room_id
      LEFT JOIN action_text_rich_texts t ON t.record_type = 'Message' AND t.record_id = m.id AND t.name = 'body'
    WHERE m.id = :id
  SQL
end
