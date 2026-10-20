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

  # RoomsController#index: where "/" goes.
  query :first_room_id, args: { user_id: :i64 }, returns: :i64?, sql: <<~SQL
    SELECT room_id FROM memberships WHERE user_id = :user_id ORDER BY id LIMIT 1
  SQL

  # Opening a room clears the membership's unread marker. The reference clears it when the room's presence
  # channel subscribes (Membership::Connectable#present, through PresenceChannel); this port has no presence
  # channel, so a room read stands in.
  execute :clear_unread, args: { user_id: :i64, room_id: :i64 }, sql: <<~SQL
    UPDATE memberships SET unread_at = NULL, updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now')
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
