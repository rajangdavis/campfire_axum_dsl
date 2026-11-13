model do
  # --- sidebar (users/sidebars/show.html.erb, users/sidebars/rooms/*) ---------------------------------------------

  # users/sidebars/rooms/_direct.html.erb's `members` and users/sidebars/rooms/_direct_placeholder.html.erb's `user`:
  # the person as fresh_user_avatar_path draws them. first_name is `name.split(' ')[0]`.
  record :SidebarUser do
    field :id, :i64
    field :name, :string
    field :first_name, :string
    field :avatar_version, :string
  end

  # One row per direct room (users/sidebars/rooms/_direct): `display` is the member-initials sentence Rails builds,
  # `dom_id` is dom_id(room, :list), and members is the `avatar__group` list, at most four.
  record :SidebarDirect do
    field :room_id, :i64
    field :user_id, :i64
    field :many, :bool
    field :updated_ms, :i64
    field :class_names, :string
    field :dom_id, :string
    field :display, :string
    field :members, list(:SidebarUser), from: :sidebar_direct_members
  end

  # One row per shared room (users/sidebars/rooms/_shared): `class_names` marks an unread room and `dom_id` is
  # dom_id(room, :list), both worked out from the row (the query is in models/room.axum.rb).
  record :SidebarRoom do
    field :id, :i64
    field :name, :string
    field :kind, :string
    field :unread, :bool

    def class_names
      if unread
        "align-center gap room btn txt-nowrap unread"
      else
        "align-center gap room btn txt-nowrap"
      end
    end

    def dom_id = "list_rooms_#{kind}_#{id}"
  end

  # layouts/application and users/sidebars/show: the administrator flag, the account's
  # restrict_room_creation_to_administrators setting, and Current.user.updated_at.to_fs(:number).
  record :SidebarFlags do
    field :admin, :i64
    field :restrict, :i64
    field :can_create, :bool
    field :avatar_version, :string
  end

  # membership.room.users.without(membership.user).presence || [ membership.user ], the first four. `room.users` has no
  # order, so SQLite walks the unique (room_id, user_id) index: user id order, as the reference shows.
  query :sidebar_direct_members, args: { room_id: :i64, user_id: :i64 }, returns: list(:SidebarUser), sql: <<~SQL
    SELECT id, name, first_name, avatar_version FROM (
      SELECT u.id AS id, u.name AS name,
             CASE WHEN instr(trim(u.name), ' ') > 0 THEN substr(trim(u.name), 1, instr(trim(u.name), ' ') - 1)
                  ELSE trim(u.name) END AS first_name,
             strftime('%Y%m%d%H%M%S', u.updated_at) AS avatar_version,
             o.user_id AS ord
      FROM users u JOIN memberships o ON o.user_id = u.id
      WHERE o.room_id = :room_id AND u.id <> :user_id
      UNION ALL
      SELECT u.id AS id, u.name AS name,
             CASE WHEN instr(trim(u.name), ' ') > 0 THEN substr(trim(u.name), 1, instr(trim(u.name), ' ') - 1)
                  ELSE trim(u.name) END AS first_name,
             strftime('%Y%m%d%H%M%S', u.updated_at) AS avatar_version,
             0 AS ord
      FROM users u
      WHERE u.id = :user_id
        AND NOT EXISTS (SELECT 1 FROM memberships o WHERE o.room_id = :room_id AND o.user_id <> :user_id)
    )
    ORDER BY ord, id
    LIMIT 4
  SQL

  # `cache membership` around each direct entry: the cache insert, cache_sidebar_direct, is in models/sidebar_direct_cache.axum.rb.

  # Current.user.memberships.visible, the direct ones: sorted by room.updated_at (newest first). display reproduces
  # `members.map { |m| m.name.split(' ')[0, 3].map { |s| s[0].capitalize }.join }.to_sentence(two_words_connector: '+')`,
  # and the single-member case `members.first.name.split(' ')[0]`.
  query :sidebar_direct_rooms, args: { user_id: :i64 }, returns: list(:SidebarDirect), sql: <<~SQL
    WITH RECURSIVE
    visible_direct AS (
      SELECT r.id AS room_id, r.updated_at AS updated_at, m.id AS membership_id, m.unread_at AS unread_at,
             m.updated_at AS membership_updated_at
      FROM rooms r JOIN memberships m ON m.room_id = r.id
      WHERE m.user_id = :user_id AND m.involvement <> 'invisible' AND r.type = 'Rooms::Direct'
    ),
    members AS (
      SELECT d.room_id AS room_id, u.id AS user_id, u.name AS name, o.user_id AS ord
      FROM visible_direct d
      JOIN memberships o ON o.room_id = d.room_id AND o.user_id <> :user_id
      JOIN users u ON u.id = o.user_id
      UNION ALL
      SELECT d.room_id AS room_id, :user_id AS user_id, u.name AS name, 0 AS ord
      FROM visible_direct d JOIN users u ON u.id = :user_id
      WHERE NOT EXISTS (SELECT 1 FROM memberships o WHERE o.room_id = d.room_id AND o.user_id <> :user_id)
    ),
    word_split(room_id, user_id, idx, rest) AS (
      SELECT room_id, user_id, 1, trim(name) FROM members
      UNION ALL
      SELECT room_id, user_id, idx + 1, ltrim(substr(rest, instr(rest, ' ') + 1))
      FROM word_split
      WHERE idx < 3 AND instr(rest, ' ') > 0
    ),
    initials AS (
      SELECT room_id, user_id,
             COALESCE(upper(substr(MAX(CASE WHEN idx = 1 THEN rest END), 1, 1)), '')
             || COALESCE(upper(substr(MAX(CASE WHEN idx = 2 THEN rest END), 1, 1)), '')
             || COALESCE(upper(substr(MAX(CASE WHEN idx = 3 THEN rest END), 1, 1)), '') AS initials
      FROM word_split
      GROUP BY room_id, user_id
    ),
    numbered AS (
      SELECT room_id, user_id, name,
             ROW_NUMBER() OVER (PARTITION BY room_id ORDER BY ord, user_id) AS rn
      FROM members
    ),
    counts AS (
      SELECT room_id, COUNT(*) AS cnt FROM members GROUP BY room_id
    )
    SELECT d.room_id AS room_id, :user_id AS user_id,
           CASE WHEN c.cnt > 1 THEN 1 ELSE 0 END AS many,
           CAST(strftime('%s', d.updated_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', d.updated_at), 4) AS INTEGER) AS updated_ms,
           CASE WHEN COALESCE((SELECT k.unread FROM axum_dsl_sidebar_direct_cache k
                                WHERE k.membership_id = d.membership_id AND k.membership_updated_at = d.membership_updated_at),
                               d.unread_at IS NOT NULL)
                THEN 'direct unread' ELSE 'direct' END AS class_names,
           'list_rooms_direct_' || d.room_id AS dom_id,
           CASE
             WHEN c.cnt = 2 THEN
               (SELECT i.initials FROM initials i JOIN numbered x ON x.room_id = i.room_id AND x.user_id = i.user_id
                WHERE i.room_id = d.room_id AND x.rn = 1)
               || '+'
               || (SELECT i.initials FROM initials i JOIN numbered x ON x.room_id = i.room_id AND x.user_id = i.user_id
                   WHERE i.room_id = d.room_id AND x.rn = 2)
             WHEN c.cnt > 2 THEN
               (SELECT group_concat(t.initials, ', ') FROM (
                  SELECT i.initials AS initials FROM initials i
                  JOIN numbered x ON x.room_id = i.room_id AND x.user_id = i.user_id
                  WHERE i.room_id = d.room_id AND x.rn < c.cnt
                  ORDER BY x.rn) t)
               || ', and '
               || (SELECT i.initials FROM initials i JOIN numbered x ON x.room_id = i.room_id AND x.user_id = i.user_id
                   WHERE i.room_id = d.room_id AND x.rn = c.cnt)
             ELSE
               (SELECT CASE WHEN instr(trim(x.name), ' ') > 0 THEN substr(trim(x.name), 1, instr(trim(x.name), ' ') - 1)
                            ELSE trim(x.name) END
                FROM numbered x WHERE x.room_id = d.room_id AND x.rn = 1)
           END AS display
    FROM visible_direct d JOIN counts c ON c.room_id = d.room_id
    ORDER BY d.updated_at DESC, d.membership_id DESC
  SQL

  # find_direct_placeholder_users: active users not already in a direct room with the current user, 20 less the
  # distinct ids in those rooms and the duplicate `including(Current.user.id)` appends.
  query :sidebar_direct_placeholders, args: { user_id: :i64 }, returns: list(:SidebarUser), sql: <<~SQL
    WITH direct_rooms AS (
      SELECT m.room_id AS room_id
      FROM memberships m JOIN rooms r ON r.id = m.room_id
      WHERE m.user_id = :user_id AND r.type = 'Rooms::Direct'
    ),
    direct_users AS (
      SELECT DISTINCT m.user_id AS user_id FROM memberships m
      WHERE m.room_id IN (SELECT room_id FROM direct_rooms)
    )
    SELECT u.id AS id, u.name AS name,
           CASE WHEN instr(trim(u.name), ' ') > 0 THEN substr(trim(u.name), 1, instr(trim(u.name), ' ') - 1)
                ELSE trim(u.name) END AS first_name,
           strftime('%Y%m%d%H%M%S', u.updated_at) AS avatar_version
    FROM users u
    WHERE u.status = 0
      AND u.id <> :user_id
      AND u.id NOT IN (SELECT user_id FROM direct_users)
    ORDER BY u.created_at ASC
    LIMIT (SELECT MAX(20 - ((SELECT COUNT(*) FROM direct_users) + 1), 0))
  SQL

  query :sidebar_flags, args: { user_id: :i64 }, returns: :SidebarFlags?, sql: <<~SQL
    SELECT CASE WHEN u.role = 1 THEN 1 ELSE 0 END AS admin,
           CASE WHEN COALESCE(json_extract(a.settings, '$.restrict_room_creation_to_administrators'), 0) IN (0, 'false')
                THEN 0 ELSE 1 END AS restrict,
           CASE WHEN u.role = 1 OR COALESCE(json_extract(a.settings, '$.restrict_room_creation_to_administrators'), 0) IN (0, 'false')
                THEN 1 ELSE 0 END AS can_create,
           strftime('%Y%m%d%H%M%S', u.updated_at) AS avatar_version
    FROM users u LEFT JOIN accounts a ON 1 = 1
    WHERE u.id = :user_id
    LIMIT 1
  SQL
end
