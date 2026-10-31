fragment do
  # A room as the sidebar and the room page need it. rooms.name is NULL for a direct room, so the queries fill it in.
  record :Room do
    field :id, :i64
    field :name, :string
  end

  # --- rooms and messages (rooms_controller.rb, messages_controller.rb, message/pagination.rb) -----------------------

  # Current.user.rooms.find_by(id:): only a room the user has a membership in (any involvement).
  query :room_for_user, args: { id: :i64, user_id: :i64 }, returns: :Room?, sql: <<~SQL
    SELECT r.id AS id, COALESCE(r.name, '') AS name
    FROM rooms r JOIN memberships m ON m.room_id = r.id
    WHERE r.id = :id AND m.user_id = :user_id
  SQL

  # The room as the cable and the broadcasts name it: Rooms::Open, Rooms::Closed or Rooms::Direct is the STI class in the
  # room's Global ID (turbo_stream_from @room, :messages and TypingNotificationsChannel's stream_for @room). Same membership
  # rule as room_for_user (Current.user.rooms.find_by).
  record :RoomClass do
    field :id, :i64
    field :class_name, :string
  end

  query :room_class_for_user, args: { id: :i64, user_id: :i64 }, returns: :RoomClass?, sql: <<~SQL
    SELECT r.id AS id, r.type AS class_name
    FROM rooms r JOIN memberships m ON m.room_id = r.id
    WHERE r.id = :id AND m.user_id = :user_id
  SQL

  # room.memberships.pluck(:user_id): who Message::Broadcasts#broadcast_unread_room tells.
  record :RoomMember do
    field :user_id, :i64
  end

  query :room_member_ids, args: { room_id: :i64 }, returns: list(:RoomMember), sql: <<~SQL
    SELECT user_id FROM memberships WHERE room_id = :room_id ORDER BY id
  SQL

  # --- the room page (rooms/show, rooms/show/_nav) -------------------------------------------------------------------

  # What the room page reads about a room. label is room_display_name(room): a direct room is called after the other
  # people in it, as ActiveSupport's to_sentence writes them; kind is the type's short name and updated_ms is
  # room.updated_at.to_fs(:epoch). message_count says whether the messages are paged (more than one page of 40),
  # and is_original whether this is Room.original (the first room created).
  record :RoomPage do
    field :id, :i64
    field :label, :string
    field :kind, :string
    field :updated_ms, :i64
    field :message_count, :i64
    field :is_original, :i64
  end

  query :room_page, args: { id: :i64, user_id: :i64 }, returns: :RoomPage?, sql: <<~SQL
    WITH p AS (SELECT :id AS rid, :user_id AS uid)
    SELECT r.id AS id,
           CASE WHEN r.type = 'Rooms::Direct' THEN COALESCE(
             (SELECT CASE WHEN o.cnt = 1 THEN o.s
                          ELSE substr(o.s, 1, length(o.s) - length(o.last_name) - 2)
                               || CASE o.cnt WHEN 2 THEN ' and ' ELSE ', and ' END || o.last_name END
              FROM (SELECT COUNT(*) AS cnt, group_concat(n.name, ', ') AS s,
                           (SELECT u2.name FROM memberships m2 JOIN users u2 ON u2.id = m2.user_id
                            WHERE m2.room_id = r.id AND m2.user_id <> p.uid ORDER BY u2.id DESC LIMIT 1) AS last_name
                    FROM (SELECT u.name AS name FROM memberships m JOIN users u ON u.id = m.user_id
                          WHERE m.room_id = r.id AND m.user_id <> p.uid ORDER BY u.id) AS n) AS o
              WHERE o.cnt > 0),
             (SELECT name FROM users WHERE id = p.uid))
           ELSE COALESCE(r.name, '') END AS label,
           CASE r.type WHEN 'Rooms::Open' THEN 'open' WHEN 'Rooms::Closed' THEN 'closed' ELSE 'direct' END AS kind,
           CAST(strftime('%s', r.updated_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', r.updated_at), 4) AS INTEGER) AS updated_ms,
           (SELECT COUNT(*) FROM messages WHERE room_id = r.id) AS message_count,
           CASE WHEN r.id = (SELECT id FROM rooms ORDER BY created_at LIMIT 1) THEN 1 ELSE 0 END AS is_original
    FROM p JOIN rooms r ON r.id = p.rid
    JOIN memberships mm ON mm.room_id = r.id AND mm.user_id = p.uid
  SQL

  # layouts/application's body_classes: "admin" for an administrator, "account-has-logo" when the account has a logo.
  record :BodyFlags do
    field :admin, :i64
    field :logo, :i64
    field :title, :string
    field :version, :string
  end

  query :body_flags, args: { user_id: :i64 }, returns: :BodyFlags?, sql: <<~SQL
    SELECT CASE WHEN u.role = 1 THEN 1 ELSE 0 END AS admin,
           COALESCE((SELECT 1 FROM active_storage_attachments WHERE record_type = 'Account' AND name = 'logo' LIMIT 1), 0) AS logo,
           CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END AS title,
           strftime('%Y%m%d%H%M%S', u.updated_at) AS version
    FROM users u WHERE u.id = :user_id
  SQL

  # WelcomeController#show: where "/" goes when the last_room cookie names no room the user is in. Its
  # last_room_visited falls back to Current.user.rooms.original (order(:created_at).first), not the first
  # membership; the sign-in redirect lands there and that visit sets the last_room cookie.
  query :first_room_id, args: { user_id: :i64 }, returns: :i64?, sql: <<~SQL
    SELECT r.id FROM rooms r JOIN memberships m ON m.room_id = r.id
    WHERE m.user_id = :user_id
    ORDER BY r.created_at LIMIT 1
  SQL

  # Membership::Connectable.connect, run when a PresenceChannel subscription is confirmed (the cable's
  # `on_subscribe:`): the room is read (unread_at cleared) and the connection counted, one more when the membership
  # was already connected within CONNECTION_TTL (60 seconds), else 1. Like `update_all`, updated_at is not touched.
  execute :connect_membership, args: { room_id: :i64, user_id: :i64 }, sql: <<~SQL
    UPDATE memberships SET
      connections = CASE WHEN connected_at IS NOT NULL AND connected_at >= strftime('%Y-%m-%d %H:%M:%f', 'now', '-60 seconds')
                         THEN connections + 1 ELSE 1 END,
      connected_at = strftime('%Y-%m-%d %H:%M:%f', 'now'),
      unread_at = NULL
    WHERE user_id = :user_id AND room_id = :room_id
  SQL

  # --- sidebar (users/sidebars_controller.rb): visible memberships, directs apart from the shared rooms --------------

  query :shared_rooms_for, args: { user_id: :i64 }, returns: list(:Room), sql: <<~SQL
    SELECT r.id AS id, COALESCE(r.name, '') AS name
    FROM rooms r JOIN memberships m ON m.room_id = r.id
    WHERE m.user_id = :user_id AND m.involvement <> 'invisible' AND r.type <> 'Rooms::Direct'
    ORDER BY r.name COLLATE NOCASE, r.id
  SQL

  # A direct room has no name of its own: it is called after the other people in it.
  query :direct_rooms_for, args: { user_id: :i64 }, returns: list(:Room), sql: <<~SQL
    SELECT r.id AS id,
           COALESCE((SELECT group_concat(u.name, ', ') FROM memberships o JOIN users u ON u.id = o.user_id
                     WHERE o.room_id = r.id AND o.user_id <> m.user_id), '') AS name
    FROM rooms r JOIN memberships m ON m.room_id = r.id
    WHERE m.user_id = :user_id AND m.involvement <> 'invisible' AND r.type = 'Rooms::Direct'
    ORDER BY r.updated_at DESC, r.id DESC
  SQL
end
