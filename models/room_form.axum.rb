fragment do
  # --- room new/edit forms (Rooms::{Opens,Closeds,Directs}Controller new/edit, app/views/rooms/{opens,closeds,directs}) ---

  # A user row the form list renders: avatar_tag links to /users/:id and the signed avatar path, and the title is
  # User#title; value is the `name.downcase` the filter menu puts in data-value (SQLite LOWER is ASCII, as the seed's
  # names are). is_current marks Current.user for the closed form's new-room hidden field.
  record :RoomFormUser do
    field :id, :i64
    field :name, :string
    field :title, :string
    field :version, :string
    field :value, :string
    field :is_current, :bool
  end

  # User.active.ordered: status 0 is active, LOWER(name) is the `ordered` scope.
  query :active_form_users, args: { current_user_id: :i64 }, returns: list(:RoomFormUser), sql: <<~SQL
    SELECT u.id AS id, u.name AS name,
           CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END AS title,
           strftime('%Y%m%d%H%M%S', u.updated_at) AS version,
           LOWER(u.name) AS value,
           CASE WHEN u.id = :current_user_id THEN 1 ELSE 0 END AS is_current
    FROM users u
    WHERE u.status = 0
    ORDER BY LOWER(u.name)
  SQL

  # A closed room's edit page partitions User.active.ordered by membership (the controller's selected and unselected
  # collections), so both lists keep the active/ordered scope.
  query :room_form_selected_users, args: { room_id: :i64, current_user_id: :i64 }, returns: list(:RoomFormUser), sql: <<~SQL
    SELECT u.id AS id, u.name AS name,
           CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END AS title,
           strftime('%Y%m%d%H%M%S', u.updated_at) AS version,
           LOWER(u.name) AS value,
           CASE WHEN u.id = :current_user_id THEN 1 ELSE 0 END AS is_current
    FROM users u JOIN memberships m ON m.user_id = u.id
    WHERE u.status = 0 AND m.room_id = :room_id
    ORDER BY LOWER(u.name)
  SQL

  query :room_form_unselected_users, args: { room_id: :i64, current_user_id: :i64 }, returns: list(:RoomFormUser), sql: <<~SQL
    SELECT u.id AS id, u.name AS name,
           CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END AS title,
           strftime('%Y%m%d%H%M%S', u.updated_at) AS version,
           LOWER(u.name) AS value,
           CASE WHEN u.id = :current_user_id THEN 1 ELSE 0 END AS is_current
    FROM users u
    WHERE u.status = 0
      AND NOT EXISTS (SELECT 1 FROM memberships m WHERE m.room_id = :room_id AND m.user_id = u.id)
    ORDER BY LOWER(u.name)
  SQL

  # The typed-empty list a new closed room starts with (@selected_users = []).
  query :no_form_users, args: {}, returns: list(:RoomFormUser), sql: <<~SQL
    SELECT 0 AS id, '' AS name, '' AS title, '' AS version, '' AS value, 0 AS is_current WHERE 0
  SQL

  # Rooms::{Opens,Closeds}Controller#set_room lands on Current.user.rooms.without_directs; the direct controller on
  # Current.user.rooms.directs. kind names the row's real type so each route can refuse the other family.
  record :RoomFormRoom do
    field :id, :i64
    field :name, :string
    field :kind, :string
    field :creator_id, :i64
  end

  query :room_form_room, args: { id: :i64, user_id: :i64 }, returns: :RoomFormRoom?, sql: <<~SQL
    SELECT r.id AS id, COALESCE(r.name, '') AS name,
           CASE r.type WHEN 'Rooms::Open' THEN 'open' WHEN 'Rooms::Closed' THEN 'closed' ELSE 'direct' END AS kind,
           r.creator_id AS creator_id
    FROM rooms r JOIN memberships m ON m.room_id = r.id
    WHERE r.id = :id AND m.user_id = :user_id
  SQL

  # Rooms::DirectsController#edit's @room.users.without(Current.user): the reference lists the other members by user id
  # (the same order room_display_name uses), so the group ping reads Jason, Kevin, JZ. `users.many? ? users.without(Current.user) : users`
  # keeps the current user only in a one-person direct room; the count check is the subquery.
  query :room_form_members, args: { room_id: :i64, user_id: :i64 }, returns: list(:RoomFormUser), sql: <<~SQL
    SELECT u.id AS id, u.name AS name,
           CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END AS title,
           strftime('%Y%m%d%H%M%S', u.updated_at) AS version,
           LOWER(u.name) AS value,
           CASE WHEN u.id = :user_id THEN 1 ELSE 0 END AS is_current
    FROM memberships m JOIN users u ON u.id = m.user_id
    WHERE m.room_id = :room_id
      AND (u.id <> :user_id OR (SELECT COUNT(*) FROM memberships m2 WHERE m2.room_id = :room_id) = 1)
    ORDER BY u.id
  SQL

  # TrackedRoomVisit#last_room_visited: the last_room cookie when it still names a room the user is in, else the
  # user's original room (Current.user.rooms.original), so the back link never points at a room they cannot open.
  query :last_form_room_id, args: { user_id: :i64, saved: :i64 }, returns: :i64?, sql: <<~SQL
    SELECT COALESCE(
      (SELECT r.id FROM rooms r JOIN memberships m ON m.room_id = r.id WHERE m.user_id = :user_id AND r.id = :saved),
      (SELECT r.id FROM rooms r JOIN memberships m ON m.room_id = r.id WHERE m.user_id = :user_id ORDER BY r.created_at LIMIT 1)
    ) AS id
  SQL

  # --- room writes (Rooms::OpensController#create, RoomsController#destroy) ----------------------------------------------

  # Room.create!: the id comes from RETURNING. type is the STI class name.
  query :create_room, args: { name: :string, creator_id: :i64, room_type: :string }, returns: :i64, sql: <<~SQL
    INSERT INTO rooms (name, creator_id, type, created_at, updated_at)
    VALUES (:name, :creator_id, :room_type, strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now'))
    RETURNING id
  SQL

  # room.memberships.grant_to(users) (Membership.insert_all: a duplicate (room, user) is skipped), default involvement "mentions".
  execute :grant_room_member, args: { room_id: :i64, user_id: :i64 }, sql: <<~SQL
    INSERT OR IGNORE INTO memberships (room_id, user_id, involvement, created_at, updated_at)
    VALUES (:room_id, :user_id, 'mentions', strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now'))
  SQL

  # Rooms::Open#grant_access_to_all_users: memberships.grant_to(User.active) after the save commits.
  execute :grant_room_to_active_users, args: { room_id: :i64 }, sql: <<~SQL
    INSERT OR IGNORE INTO memberships (room_id, user_id, involvement, created_at, updated_at)
    SELECT :room_id, u.id, 'mentions', strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now')
    FROM users u WHERE u.status = 0 ORDER BY u.id
  SQL

  # Room#destroy: has_many :messages (dependent: :destroy: each message's boosts, body, attachment and FTS row go with it),
  # has_many :memberships (dependent: :delete_all), then the room.
  execute :delete_room_boosts, args: { room_id: :i64 }, sql: <<~SQL
    DELETE FROM boosts WHERE message_id IN (SELECT id FROM messages WHERE room_id = :room_id)
  SQL

  execute :delete_room_bodies, args: { room_id: :i64 }, sql: <<~SQL
    DELETE FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id IN (SELECT id FROM messages WHERE room_id = :room_id)
  SQL

  execute :delete_room_attachments, args: { room_id: :i64 }, sql: <<~SQL
    DELETE FROM active_storage_attachments WHERE record_type = 'Message' AND record_id IN (SELECT id FROM messages WHERE room_id = :room_id)
  SQL

  execute :delete_room_message_index, args: { room_id: :i64 }, sql: <<~SQL
    DELETE FROM message_search_index WHERE rowid IN (SELECT id FROM messages WHERE room_id = :room_id)
  SQL

  execute :delete_room_messages, args: { room_id: :i64 }, sql: <<~SQL
    DELETE FROM messages WHERE room_id = :room_id
  SQL

  execute :delete_room_memberships, args: { room_id: :i64 }, sql: <<~SQL
    DELETE FROM memberships WHERE room_id = :room_id
  SQL

  query :delete_room_row, args: { room_id: :i64 }, returns: :i64, sql: <<~SQL
    DELETE FROM rooms WHERE id = :room_id RETURNING id
  SQL
end