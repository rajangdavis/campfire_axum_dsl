model do
  # --- room new/edit forms (Rooms::{Opens,Closeds,Directs}Controller new/edit, app/views/rooms/{opens,closeds,directs}) ---

  # A user row the form list renders: avatar_tag links to /users/:id and the signed avatar path, and the title is
  # User#title; value is the `name.downcase` the filter menu puts in data-value (SQLite LOWER is ASCII, as the seed's
  # names are).
  record :RoomFormUser do
    field :id, :i64
    field :name, :string
    field :title, :string
    field :version, :string
    field :value, :string
  end

  # The active, selected and unselected lists (active_form_users, room_form_selected_users, room_form_unselected_users)
  # are relations on User, in models/user.axum.rb.

  # The typed-empty list a new closed room starts with (@selected_users = []).
  query :no_form_users, args: {}, returns: list(:RoomFormUser), sql: <<~SQL
    SELECT 0 AS id, '' AS name, '' AS title, '' AS version, '' AS value WHERE 0
  SQL

  # Rooms::{Opens,Closeds}Controller#set_room lands on Current.user.rooms.without_directs; the direct controller on
  # Current.user.rooms.directs. kind names the row's real type so each route can refuse the other family.
  record :RoomFormRoom do
    field :id, :i64
    field :name, :string
    field :kind, :string
    field :creator_id, :i64
  end

  # TrackedRoomVisit#last_room_visited: the last_room cookie when it still names a room the user is in, else the
  # user's original room (Current.user.rooms.original), so the back link never points at a room they cannot open. 0 when
  # the user is in no room.
  def last_form_room_id(user_id, saved)
    visited = room_for_user(id: saved, user_id: user_id)
    visited&.id || (first_room_id(user_id: user_id) || 0)
  end

  # --- room writes (Rooms::OpensController#create, RoomsController#destroy) ----------------------------------------------

  # The membership grants (grant_room_member, grant_room_to_active_users, grant_room_members, grant_direct_members) are in
  # models/membership.axum.rb.

  # RoomsController#set_room is `Current.user.rooms.without_directs.find_by` (a room the user is not in, or a direct one, redirects to /
  # with the "Room not found or inaccessible" alert, carried as in rooms.axum.rb), then ensure_can_administer (403 unless an
  # administrator or the creator), update!, revise, and broadcast_update_room: every person still in the room has the room's sidebar
  # entry replaced (broadcast_replace_to user, :rooms, target: [ @room, :list ]), the html rendered once. A person taken out gets no
  # broadcast; Rails instead closes their cable connections once the transaction has committed (Membership after_destroy_commit ->
  # user.reset_remote_connections, a `{"type":"disconnect","reason":"remote","reconnect":true}` frame), which
  # `close_remote_connections` does. Their client then reconnects, the endpoint rejects the room's channels (`member_of:`), and
  # the UnreadRoomsChannel reconnect reloads the sidebar frame, which no longer lists the room.

  # Rooms::Direct.find_for(users): the direct room whose member set is exactly `users` (User.where(id: ids + [Current.user.id]),
  # so unknown ids and repeats drop out), the lowest id first, as `all.joins(:users).detect` meets them.
  query :direct_room_for, args: { ids: :string }, returns: :i64?, sql: <<~SQL
    WITH wanted AS (SELECT DISTINCT u.id AS id FROM users u WHERE u.id IN (SELECT value FROM json_each('[' || :ids || ']')))
    SELECT r.id FROM rooms r JOIN memberships m ON m.room_id = r.id
    WHERE r.type = 'Rooms::Direct'
    GROUP BY r.id
    HAVING COUNT(*) = (SELECT COUNT(*) FROM wanted) AND SUM(m.user_id IN (SELECT id FROM wanted)) = (SELECT COUNT(*) FROM wanted)
    ORDER BY r.id LIMIT 1
  SQL
end
