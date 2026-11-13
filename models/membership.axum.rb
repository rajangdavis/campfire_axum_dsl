model :Membership, table: :memberships do
  # app/models/membership.rb and membership/connectable.rb. Not declared: `with_ordered_room` (order("LOWER(rooms.name)")),
  # `connected` and `disconnected` (a range of connected_at from CONNECTION_TTL.ago).
  belongs_to :room, model: :Room
  belongs_to :user, model: :User

  # Membership#unread?: the room has messages the person has not read (unread_at is set).
  expr :unread_marker, type: :bool, sql: "{t}.unread_at IS NOT NULL"
  # Membership::Connectable::CONNECTION_TTL.ago: the instant 60 seconds back; a membership connected before it is disconnected.
  expr :connection_cutoff, type: :string, sql: "strftime('%Y-%m-%d %H:%M:%f', 'now', '-60 seconds')"
  # Membership::Connectable.connect: the connection count after a connect (one more while still connected within CONNECTION_TTL, else 1).
  expr :next_connections, type: :i64,
       sql: "CASE WHEN {t}.connected_at IS NOT NULL AND {t}.connected_at >= strftime('%Y-%m-%d %H:%M:%f', 'now', '-60 seconds') THEN {t}.connections + 1 ELSE 1 END"

  # enum :involvement, %w[ invisible nothing mentions everything ], prefix: :involved_in: a scope for each value and its
  # `not_` twin.
  scope :involved_in_invisible, -> { where(involvement: "invisible") }
  scope :involved_in_nothing, -> { where(involvement: "nothing") }
  scope :involved_in_mentions, -> { where(involvement: "mentions") }
  scope :involved_in_everything, -> { where(involvement: "everything") }
  scope :not_involved_in_invisible, -> { where_not(involvement: "invisible") }
  scope :not_involved_in_nothing, -> { where_not(involvement: "nothing") }
  scope :not_involved_in_mentions, -> { where_not(involvement: "mentions") }
  scope :not_involved_in_everything, -> { where_not(involvement: "everything") }

  scope :without_direct_rooms, -> { joins(:room).where_not(room: { type: "Rooms::Direct" }) }
  scope :visible, -> { where_not(involvement: "invisible") }
  scope :unread, -> { where_not(unread_at: nil) }

  # User#deactivate: the memberships outside direct rooms go (the statements around it are in models/user.axum.rb).
  execute :deactivate_user_memberships, args: { id: :i64 } do
    where(user_id: arg(:id), room_id: Room.where_not(type: "Rooms::Direct").select(:id)).delete
  end

  # Rooms::InvolvementsController#show: the membership's involvement.
  query :involvement_for, args: { room_id: :i64, user_id: :i64 }, returns: :string? do
    where(room_id: arg(:room_id), user_id: arg(:user_id)).pick(:involvement)
  end

  execute :set_involvement, args: { room_id: :i64, user_id: :i64, involvement: :string } do
    where(room_id: arg(:room_id), user_id: arg(:user_id)).update(involvement: arg(:involvement))
  end

  # `when @membership.involved_in_invisible?` (not for a direct room): broadcast_remove_to the user, :rooms.
  query :involvement_hides_room, args: { room_id: :i64, user_id: :i64 }, returns: list(:RoomMember) do
    joins(:room).where(room_id: arg(:room_id), user_id: arg(:user_id), involvement: "invisible").where_not(room: { type: "Rooms::Direct" }).select(:user_id)
  end

  # `when involvement_previously_was.invisible?`: broadcast_prepend_to the user, :rooms into shared_rooms.
  query :involvement_shows_room, args: { room_id: :i64, user_id: :i64, previous: :string }, returns: list(:RoomMember), sql: <<~SQL
    SELECT m.user_id AS user_id FROM memberships m JOIN rooms r ON r.id = m.room_id
    WHERE m.room_id = :room_id AND m.user_id = :user_id AND m.involvement <> 'invisible' AND :previous = 'invisible'
      AND r.type <> 'Rooms::Direct'
  SQL

  # room.memberships.pluck(:user_id).
  query :room_member_ids, args: { room_id: :i64 }, returns: list(:RoomMember) do
    where(room_id: arg(:room_id)).order(:id).select(:user_id)
  end

  # The people `revoke_room_members` is about to remove (`@room.users.where.not(id: ids)`), read before the transaction deletes
  # their rows: Membership `after_destroy_commit { user.reset_remote_connections }` needs them afterwards.
  query :revoked_room_members, args: { room_id: :i64, ids: :string }, returns: list(:RoomMember) do
    where(room_id: arg(:room_id)).where_not(user_id: in_ids(arg(:ids))).order(:id).select(:user_id)
  end

  execute :revoke_room_members, args: { room_id: :i64, ids: :string } do
    where(room_id: arg(:room_id)).where_not(user_id: in_ids(arg(:ids))).delete
  end

  # room.memberships.grant_to(users) (Membership.insert_all: a duplicate (room, user) is skipped), default involvement "mentions".
  execute :grant_room_member, args: { room_id: :i64, user_id: :i64 } do
    insert(room_id: arg(:room_id), user_id: arg(:user_id), involvement: "mentions", on_duplicate: :skip)
  end

  # Rooms::Open#grant_access_to_all_users: memberships.grant_to(User.active) after the save commits.
  execute :grant_room_to_active_users, args: { room_id: :i64 } do
    insert_from(User.active.order(:id), room_id: arg(:room_id), user_id: :id, involvement: "mentions", on_duplicate: :skip)
  end

  # `@room.memberships.revise(granted: User.where(id: ids), revoked: @room.users.where.not(id: ids))`, in the order
  # `grant_to` then `revoke_from`. `ids` is the id list joined with commas (numbers only), read as a JSON array: the DSL
  # passes no list to SQL. Membership.insert_all skips a person who is already a member.
  execute :grant_room_members, args: { room_id: :i64, ids: :string } do
    insert_from(User.where(id: in_ids(arg(:ids))).order(:id), room_id: arg(:room_id), user_id: :id, involvement: "mentions", on_duplicate: :skip)
  end

  # memberships.grant_to(users) with Rooms::Direct#default_involvement, "everything", in User.where's id order.
  execute :grant_direct_members, args: { room_id: :i64, ids: :string } do
    insert_from(User.where(id: in_ids(arg(:ids))).order(:id), room_id: arg(:room_id), user_id: :id, involvement: "everything", on_duplicate: :skip)
  end

  # Message's `after_create_commit -> { room.receive(self) }`, Room#unread_memberships: every visible membership
  # (involvement not invisible) whose cable connection is not live (connected_at nil or older than CONNECTION_TTL,
  # 60 seconds), except the creator's, is marked unread at the message's created_at. (Room#push_later's web push is
  # a job this service does not run.) `update_all` as Rails' unread_memberships.update_all, with updated_at set by hand.
  execute :receive_message, args: { room_id: :i64, creator_id: :i64, created_at: :string } do
    where(connected_at: nil).or(where(lt(:connected_at, expr(:connection_cutoff))))
      .where(room_id: arg(:room_id)).visible.where_not(user_id: arg(:creator_id))
      .update_all(unread_at: arg(:created_at), updated_at: expr(:now))
  end

  # Membership::Connectable.connect, run when a PresenceChannel subscription is confirmed (the cable's
  # `on_subscribe:`): the room is read (unread_at cleared) and the connection counted, one more when the membership
  # was already connected within CONNECTION_TTL (60 seconds), else 1. Like `update_all`, updated_at is not touched.
  execute :connect_membership, args: { room_id: :i64, user_id: :i64 } do
    where(user_id: arg(:user_id), room_id: arg(:room_id))
      .update_all(connections: expr(:next_connections), connected_at: expr(:now), unread_at: nil)
  end

  # User#grant_membership_to_open_rooms (after_create_commit): Membership.insert_all over Rooms::Open, the default involvement.
  execute :grant_open_rooms_to, args: { user_id: :i64 } do
    insert_from(Room.opens.order(:id), room_id: :id, user_id: arg(:user_id), involvement: "mentions", on_duplicate: :skip)
  end
end
