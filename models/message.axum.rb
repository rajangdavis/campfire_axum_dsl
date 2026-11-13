model :Message, table: :messages do
  # app/models/message.rb and its concerns. Not declared: `belongs_to :room, touch: true` (a touching association); the
  # scopes with_creator, with_attachment_details, with_boosts
  # (preload), search (a MATCH join), and Pagination's last_page, before, after, page_before, page_after, page_updated_since
  # (they take a message or use `last`).
  belongs_to :room, model: :Room
  belongs_to :creator, model: :User
  has_many :boosts, dependent: :destroy
  # has_rich_text :body, has_one_attached :attachment and Message::Searchable's FTS row, as what goes with a destroyed
  # message: every row that names it (the attachment row; Rails purges the blob later, see purge_blobs).
  has_many :rich_texts, table: :action_text_rich_texts, as: :record, dependent: :delete_all
  has_many :attachments, table: :active_storage_attachments, as: :record, dependent: :delete_all
  has_one :search_row, table: :message_search_index, foreign_key: :rowid, dependent: :delete_all
  # The message's body: its action_text_rich_texts row named "body" (none for an attachment-only message).
  has_one :body_text, -> { where(name: "body") }, table: :action_text_rich_texts, as: :record

  # `{t}` is the messages table. created_ms, updated_ms, created_iso and created_iso_ms are the concern Timestamps.
  include :Timestamps

  # Message#to_param: the client's id for the message, else the row's.
  expr :message_param, type: :string, sql: "COALESCE({t}.client_message_id, CAST({t}.id AS TEXT))"
  # MessageRow#renderable: the message's creator row exists (the users table is left-joined, so no `{t}`).
  expr :renderable, type: :bool, sql: "CASE WHEN users.id IS NULL THEN 0 ELSE 1 END"
  # Message#attachment.filename (has_one_attached :attachment), '' for a message without a file.
  expr :attachment_filename, type: :string,
       sql: "COALESCE((SELECT b.filename FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id = a.blob_id WHERE a.record_type = 'Message' AND a.record_id = {t}.id AND a.name = 'attachment' LIMIT 1), '')"
  # Message.before(message) as the bot API pages with it: created before the message :before of the room, or every message when :before is 0.
  expr :before_cursor, type: :bool, args: { room_id: :i64, before: :i64 },
       sql: ":before = 0 OR {t}.created_at < (SELECT a.created_at FROM messages a WHERE a.id = :before AND a.room_id = :room_id)"

  scope :ordered, -> { order(:created_at) }
  scope :first_page, -> { ordered.limit(40) }
  scope :page_created_since, ->(time) { where(gt(:created_at, time)).first_page }
  # A message as MessageRow reads it: its creator (left join: the user may be gone), its room and its body row (left
  # join: '' when there is none). Every MessageRow query is this scope with its own conditions, order and limit.
  scope :message_rows, -> {
    left_joins(:creator).joins(:room).left_joins(:body_text).select(
      id: :id, param: expr(:message_param), creator_id: :creator_id,
      creator_name: coalesce(col(:creator, :name), ""),
      creator_title: coalesce(expr(:user_title, :creator), ""),
      avatar_version: coalesce(expr(:updated_at_number, :creator), ""),
      created_at: :created_at, created_ms: expr(:created_ms), updated_ms: expr(:updated_ms), created_iso: expr(:created_iso),
      room_id: :room_id, renderable: expr(:renderable), room_label: expr(:direct_room_label, :room),
      body: coalesce(col(:body_text, :body), "")
    )
  }

  # next_page_params: `@room.messages.before(first).exists?` and `.after(last).exists?` (an id that names no message gives false).
  query :bot_older_exists, args: { room_id: :i64, id: :i64 }, returns: :bool do
    where(room_id: arg(:room_id)).where(lt(:created_at, Message.where(id: arg(:id)).select(:created_at))).exists
  end

  query :bot_newer_exists, args: { room_id: :i64, id: :i64 }, returns: :bool do
    where(room_id: arg(:room_id)).where(gt(:created_at, Message.where(id: arg(:id)).select(:created_at))).exists
  end

  # RemoveBannedContentJob (User#remove_banned_content): the person's messages, read for the broadcasts before they go.
  query :user_messages, args: { user_id: :i64 }, returns: list(:BannedMessage) do
    joins(:room).where(creator_id: arg(:user_id)).select(:room_id, param: expr(:message_param), room_class: col(:room, :type)).order(:id)
  end

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

  # message_mentions (the users a body names) is in models/user.axum.rb.


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
    field :booster_name, :string
    field :content, :string

    # The aria-label, as messages/boosts/_boost writes it.
    def label = "#{booster_name} boosted #{content}"
  end

  # Message.ordered.last(40): the newest 40 by created_at, handed back oldest to newest.

  query :last_page, args: { room_id: :i64 }, returns: list(:MessageRow) do
    message_rows.where(room_id: arg(:room_id)).order(:created_at, :id).last(40)
  end
  # page_before(message): the 40 messages created before :before (a message of this room), oldest to newest.
  query :messages_before, args: { room_id: :i64, before: :i64 }, returns: list(:MessageRow) do
    message_rows.where(room_id: arg(:room_id)).where(lt(:created_at, Message.where(id: arg(:before), room_id: arg(:room_id)).select(:created_at))).order(:created_at, :id).last(40)
  end
  # page_after(message): the 40 messages created after :after (a message of this room), oldest to newest.
  query :messages_after, args: { room_id: :i64, after: :i64 }, returns: list(:MessageRow) do
    message_rows.where(room_id: arg(:room_id)).where(gt(:created_at, Message.where(id: arg(:after), room_id: arg(:room_id)).select(:created_at))).order(:created_at, :id).limit(40)
  end
  # page_around(message): page_before + [message] + page_after (RoomsController#find_messages for /rooms/:id/@:message_id);
  # empty when the message is not in the room, and the page then falls back to the last page.
  query :messages_around, args: { room_id: :i64, around: :i64 }, returns: list(:MessageRow) do
    message_rows.where(id: arg(:around))
      .or(where(id: Message.where(room_id: arg(:room_id)).where(lt(:created_at, Message.where(id: arg(:around), room_id: arg(:room_id)).select(:created_at))).order(created_at: :desc, id: :desc).limit(40).select(:id)))
      .or(where(id: Message.where(room_id: arg(:room_id)).where(gt(:created_at, Message.where(id: arg(:around), room_id: arg(:room_id)).select(:created_at))).order(created_at: :asc, id: :asc).limit(40).select(:id)))
      .where(room_id: arg(:room_id)).order(:created_at, :id)
  end

  # --- the bot API (controllers/bot_messages.axum.rb): a message as messages/_message.json.jbuilder draws it (record :BotMessage) ---
  # find_paged_messages (messages_controller.rb): the last 40 of the room, or of those created before :before (0 for none),
  # oldest to newest.
  query :bot_messages_last, args: { room_id: :i64, before: :i64 }, returns: list(:BotMessage) do
    left_joins(:creator).left_joins(:body_text).where(room_id: arg(:room_id))
      .where(expr(:before_cursor, room_id: arg(:room_id), before: arg(:before)))
      .select(id: :id, created_at: expr(:created_iso_ms), body: coalesce(col(:body_text, :body), ""), filename: expr(:attachment_filename),
              creator_id: :creator_id, creator_name: coalesce(col(:creator, :name), ""), creator_role: coalesce(expr(:role_name, :creator), ""),
              avatar_version: coalesce(expr(:updated_at_number, :creator), ""), room_id: :room_id)
      .order(:created_at, :id).last(40)
  end

  # page_after(message): the first 40 messages created after :after.
  query :bot_messages_after, args: { room_id: :i64, after: :i64 }, returns: list(:BotMessage) do
    left_joins(:creator).left_joins(:body_text).where(room_id: arg(:room_id))
      .where(gt(:created_at, Message.where(id: arg(:after), room_id: arg(:room_id)).select(:created_at)))
      .select(id: :id, created_at: expr(:created_iso_ms), body: coalesce(col(:body_text, :body), ""), filename: expr(:attachment_filename),
              creator_id: :creator_id, creator_name: coalesce(col(:creator, :name), ""), creator_role: coalesce(expr(:role_name, :creator), ""),
              avatar_version: coalesce(expr(:updated_at_number, :creator), ""), room_id: :room_id)
      .order(:created_at, :id).limit(40)
  end

  # One message of the room, as above.
  query :bot_message, args: { room_id: :i64, id: :i64 }, returns: :BotMessage? do
    left_joins(:creator).left_joins(:body_text).where(id: arg(:id), room_id: arg(:room_id))
      .select(id: :id, created_at: expr(:created_iso_ms), body: coalesce(col(:body_text, :body), ""), filename: expr(:attachment_filename),
              creator_id: :creator_id, creator_name: coalesce(col(:creator, :name), ""), creator_role: coalesce(expr(:role_name, :creator), ""),
              avatar_version: coalesce(expr(:updated_at_number, :creator), ""), room_id: :room_id)
  end

  # --- search (searches_controller.rb, message/searchable.rb): Current.user.reachable_messages.search(q).last(100) ----
  # `search` ends in `.ordered` (created_at), so the last 100 are the newest by creation time, oldest first; an id order
  # agrees only while ids follow creation (the custom_styles, restricted and crowd seeds have a message where they do not).

  # `by_id` 1 orders by id instead, as once-campfire-verification's search contract does (bench/contracts.rb), for a
  # benchmark run only: setting :search_order_by_id in campfire.axum.rb.
  query :search_messages, args: { user_id: :i64, q: :string, by_id: :i64 }, returns: list(:MessageRow), sql: <<~SQL
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
      ORDER BY CASE WHEN :by_id = 1 THEN m.id END DESC, m.created_at DESC LIMIT 100
    ) ORDER BY CASE WHEN :by_id = 1 THEN id END ASC, created_at ASC
  SQL

  # Message.none, for a blank query (FTS5 refuses an empty MATCH).
  query :no_messages, args: {}, returns: list(:MessageRow), sql: <<~SQL
    SELECT 0 AS id, '' AS param, 0 AS creator_id, '' AS creator_name, '' AS creator_title, '' AS avatar_version, '' AS created_at,
           0 AS created_ms, 0 AS updated_ms, '' AS created_iso, 0 AS room_id, 0 AS renderable, '' AS room_label, '' AS body WHERE 0
  SQL

  # Rails' Message#create!: the id comes from RETURNING, not last_insert_rowid(), because the pool may hand the
  # next statement a different connection. The INSERT always yields one row, so a no-row result is a DB error
  # (which rolls the transaction back); inside the transaction the id is therefore non-nil.
  # The message's created_at is read once (message_stamp, first in the transaction) and written by create_message and
  # receive_message alike, so unread_at is the stored created_at without receive_message reading messages back.
  # Message's `after_create_commit -> { room.receive(self) }` is receive_message, in models/membership.axum.rb.

  # Message's `before_create -> { self.client_message_id ||= Random.uuid }`: a v4 UUID for a message that came without one (a bot's).
  query :random_uuid, args: {}, returns: :string, sql: <<~SQL
    SELECT lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))), 2) || '-'
           || substr('89ab', (abs(random()) % 4) + 1, 1) || substr(lower(hex(randomblob(2))), 2) || '-' || lower(hex(randomblob(6)))
  SQL

  # ActiveStorage::PurgeJob for blobs whose attachment went (a destroyed message's file): each blob with what hangs off it --
  # its variant records and their image blobs, and a video's preview_image blob with that blob's variants. `ids` is the
  # blobs' ids joined with commas; purge_set answers the whole set, read before the attachments that name them go.
  query :purge_set, args: { ids: :string }, returns: :string, sql: <<~SQL
    WITH base(id) AS (SELECT value FROM json_each('[' || :ids || ']')),
    previews(id) AS (SELECT a.blob_id FROM active_storage_attachments a WHERE a.record_type = 'ActiveStorage::Blob' AND a.name = 'preview_image' AND a.record_id IN (SELECT id FROM base)),
    owners(id) AS (SELECT id FROM base UNION SELECT id FROM previews),
    variants(id) AS (SELECT a.blob_id FROM active_storage_attachments a JOIN active_storage_variant_records v ON a.record_type = 'ActiveStorage::VariantRecord' AND a.record_id = v.id WHERE v.blob_id IN (SELECT id FROM owners))
    SELECT COALESCE(group_concat(id), '') FROM (SELECT id FROM owners UNION SELECT id FROM variants)
  SQL

  # The timestamp create_message stores and receive_message marks unread at: SQLite's 'now' as every created_at here is
  # written. Read inside the transaction (an IMMEDIATE one, so no other writer sits between this and the insert).
  query :message_stamp, args: {}, returns: :string, sql: "SELECT strftime('%Y-%m-%d %H:%M:%f', 'now')"

  query :create_message, args: { room_id: :i64, creator_id: :i64, client_message_id: :string, created_at: :string }, returns: :i64 do
    insert(client_message_id: arg(:client_message_id), room_id: arg(:room_id), creator_id: arg(:creator_id),
           created_at: arg(:created_at), updated_at: arg(:created_at), returning: :id)
  end

  execute :touch_message, args: { message_id: :i64 } do
    where(id: arg(:message_id)).touch
  end

  # has_one_attached :attachment: the attachment row of a message's file (attach_message_file) is in models/attachment.axum.rb.

  # The new row as the page reads it: creator_name and created_at come from the database, not from bind values.
  query :message_row, args: { id: :i64 }, returns: :MessageRow? do
    message_rows.where(id: arg(:id))
  end
  # Messages::BoostsController#set_boost and #destroy: `@message.boosts.find_by!(id:, booster: Current.user)` then `destroy!`, in one
  # statement: the message id of the boost that was deleted, or nothing (the controller answers 404).
  query :delete_own_boost, args: { message_id: :i64, id: :i64, booster_id: :i64 }, returns: :i64?, sql: <<~SQL
    DELETE FROM boosts WHERE id = :id AND message_id = :message_id AND booster_id = :booster_id RETURNING message_id
  SQL

  # Message#destroy: has_many :boosts (dependent: :destroy), has_rich_text :body, has_one_attached :attachment (the
  # attachment row goes with the message; Rails purges the blob later, a job this service does not run) and
  # Message::Searchable#remove_from_index.
  execute :destroy_message, args: { id: :i64 } do
    where(id: arg(:id)).destroy
  end

  # The message's dom id part (`to_key`, the client_message_id), which the Turbo Stream names, for a caller that read
  # no MessageRow.
  query :message_dom_param, args: { id: :i64 }, returns: :MessageParam? do
    where(id: arg(:id)).select(param: expr(:message_param))
  end

  # RemoveBannedContentJob: every message the person wrote, each as Message#destroy takes it.
  execute :destroy_user_messages, args: { user_id: :i64 } do
    where(creator_id: arg(:user_id)).destroy
  end

  # Message.page_created_since(time): the first 40 messages created after :since (epoch ms), oldest first.
  query :messages_created_since, args: { room_id: :i64, since: :i64 }, returns: list(:MessageRow) do
    message_rows.where(room_id: arg(:room_id)).where(gt(expr(:created_ms), arg(:since))).order(:created_at, :id).limit(40)
  end
  # Message.without(new).page_updated_since(time): the last 40 messages updated after :since that are not in the
  # created-since page, oldest first.
  query :messages_updated_since, args: { room_id: :i64, since: :i64 }, returns: list(:MessageRow) do
    message_rows.where(room_id: arg(:room_id)).where(gt(expr(:updated_ms), arg(:since)))
                .where_not(id: Message.where(room_id: arg(:room_id)).where(gt(expr(:created_ms), arg(:since))).order(:created_at, :id).limit(40).select(:id))
                .order(:created_at, :id).last(40)
  end
  # @room.messages.find(id): the id of a message of this room, or nothing (the controller answers 404).
  query :room_message_id, args: { room_id: :i64, id: :i64 }, returns: :i64? do
    where(id: arg(:id), room_id: arg(:room_id)).pick(:id)
  end

  # set_pagination_headers (by_bots_controller.rb): X-Total-Count is @room.messages.count.
  query :room_message_count, args: { room_id: :i64 }, returns: :i64 do
    where(room_id: arg(:room_id)).count
  end

  # Message.create! for a text message (a webhook's reply, receive_text_reply_to): the message, its Action Text body
  # and its FTS row, the room touched and Room#receive's unread marks, in one transaction. The new message's id.
  def create_text_message(room_id, creator_id, client_message_id, body, indexed)
    has_body = body != ""
    transaction do
      stamp = message_stamp
      id = create_message(room_id: room_id, creator_id: creator_id, created_at: stamp, client_message_id: client_message_id)
      if has_body
        create_message_body(message_id: id, body: body)
      end
      index_message(message_id: id, body: indexed)
      touch_message_room(message_id: id)
      receive_message(room_id: room_id, creator_id: creator_id, created_at: stamp)
      id
    end
  end

  # `@room.messages.create_with_attachment!`: the same message with an optional file (Message::Attachment,
  # has_one_attached :attachment). The file is written to Active Storage's Disk service first (a failed write answers
  # 500 before any row exists); the blob and attachment rows go in the message's transaction and do nothing without a
  # file. Then Message#process_attachment: the :thumb variant of an image (models/variant.axum.rb). The new message's id.
  def create_room_message(room_id, creator_id, client_message_id, body, indexed, attachment)
    file_name = attachment&.filename || ""
    file_type = attachment&.content_type || ""
    file_size = attachment&.size || 0
    file_checksum = attachment&.checksum || ""
    file_metadata = attachment&.metadata || ""
    attachment_present = !attachment.nil?
    key = if attachment.nil?
      ""
    else
      attachment.store(setting(:storage))
    end
    has_body = body != ""
    message_id = transaction do
      stamp = message_stamp
      id = create_message(room_id: room_id, creator_id: creator_id, created_at: stamp, client_message_id: client_message_id)
      if has_body
        create_message_body(message_id: id, body: body)
      end
      if attachment_present
        insert_blob(key: key, filename: file_name, content_type: file_type, metadata: file_metadata, byte_size: file_size, checksum: file_checksum)
        attach_message_file(message_id: id, key: key)
      end
      index_message(message_id: id, body: indexed)
      touch_message_room(message_id: id)
      receive_message(room_id: room_id, creator_id: creator_id, created_at: stamp)
      id
    end
    if attachment_present && variable_content_type(file_type)
      thumb = thumb_variation(content_type: file_type) || raise("the thumb variation was not read")
      storage = setting(:storage)
      variant = image_variant("#{storage}/#{key[0, 2].to_s}/#{key[2, 2].to_s}/#{key}", variant_filename(file_name, thumb.format), 1200, 800)
      variant_name = variant&.filename || ""
      variant_type = variant&.content_type || ""
      variant_metadata = variant&.metadata || ""
      variant_size = variant&.size || 0
      variant_checksum = variant&.checksum || ""
      variant_key = if variant.nil?
        ""
      else
        variant.store(storage)
      end
      if variant_key != ""
        transaction do
          create_variant_record(blob_key: key, digest: thumb.digest)
          insert_blob(key: variant_key, filename: variant_name, content_type: variant_type, metadata: variant_metadata, byte_size: variant_size, checksum: variant_checksum)
          attach_variant_image(blob_key: key, digest: thumb.digest, variant_key: variant_key)
        end
      end
    end
    message_id
  end

  # `message.update!(body:)`: the Action Text body saved (touching the message and, through it, the room) and
  # Message::Searchable#update_in_index keeping the FTS row at the plain text, in one transaction. The message's id.
  def update_message(message_id, body, indexed)
    transaction do
      save_message_body(message_id: message_id, body: body)
      touch_message(message_id: message_id)
      touch_message_room(message_id: message_id)
      reindex_message(message_id: message_id, body: indexed)
      message_id
    end
  end

  # `message.boosts.create!(content:)` (Boost belongs_to :message, touch: true: the message and its room are touched).
  # The new boost's id.
  def boost_message(message_id, booster_id, content)
    transaction do
      touch_message(message_id: message_id)
      touch_message_room(message_id: message_id)
      create_boost(message_id: message_id, booster_id: booster_id, content: content)
    end
  end

  # `message.destroy`: the message goes with its boosts, body, attachment and FTS row, the room is touched
  # (belongs_to :room, touch: true) and the attached blobs are purged with their variants, in one transaction.
  def destroy_room_message(message_id)
    purged = purge_set(ids: message_blob_ids(message_id: message_id))
    transaction do
      touch_message_room(message_id: message_id)
      destroy_message(id: message_id)
      purge_blob_dependents(ids: purged)
      purge_blob_variant_records(ids: purged)
      purge_blobs(ids: purged)
    end
  end
end
