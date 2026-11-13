model :Room, table: :rooms do
  # app/models/room.rb. Not declared: the `ordered` scope (order("LOWER(name)")), `belongs_to :creator`'s default and
  # the STI classes Rooms::Open, Rooms::Closed and Rooms::Direct (the scopes below stand for them).
  has_many :memberships, dependent: :delete_all
  has_many :users, through: :memberships
  has_many :messages, dependent: :destroy
  belongs_to :creator, model: :User

  # `{t}` is the rooms table. `updated_ms` is the concern Timestamps, `lower_name` the concern Named.
  include :Timestamps
  include :Named

  # A room's type by its short name (Rooms::Open is open).
  expr :room_kind, type: :string,
       sql: "CASE {t}.type WHEN 'Rooms::Open' THEN 'open' WHEN 'Rooms::Closed' THEN 'closed' ELSE 'direct' END"
  # room_display_name(room, for_user: nil): a direct room's members' names joined ("A, B, and C"), else the room's name; {t} is rooms.
  expr :direct_room_label, type: :string,
       sql: "CASE WHEN {t}.type = 'Rooms::Direct' THEN COALESCE((SELECT CASE WHEN o.cnt = 1 THEN o.s ELSE substr(o.s, 1, length(o.s) - length(o.last_name) - 2) || CASE o.cnt WHEN 2 THEN ' and ' ELSE ', and ' END || o.last_name END FROM (SELECT COUNT(*) AS cnt, group_concat(n.name, ', ') AS s, (SELECT u2.name FROM memberships m2 JOIN users u2 ON u2.id = m2.user_id WHERE m2.room_id = {t}.id ORDER BY u2.id DESC LIMIT 1) AS last_name FROM (SELECT u3.name AS name FROM memberships m3 JOIN users u3 ON u3.id = m3.user_id WHERE m3.room_id = {t}.id ORDER BY u3.id) AS n) AS o WHERE o.cnt > 0), '') ELSE COALESCE({t}.name, '') END"
  # room_display_name(room, for_user:): a direct room is called after the people in it other than the viewer ("A, B, and C").
  expr :room_label_for, type: :string, args: { user_id: :i64 },
       sql: "CASE WHEN {t}.type = 'Rooms::Direct' THEN COALESCE((SELECT CASE WHEN o.cnt = 1 THEN o.s ELSE substr(o.s, 1, length(o.s) - length(o.last_name) - 2) || CASE o.cnt WHEN 2 THEN ' and ' ELSE ', and ' END || o.last_name END FROM (SELECT COUNT(*) AS cnt, group_concat(n.name, ', ') AS s, (SELECT u2.name FROM memberships m2 JOIN users u2 ON u2.id = m2.user_id WHERE m2.room_id = {t}.id AND m2.user_id <> :user_id ORDER BY u2.id DESC LIMIT 1) AS last_name FROM (SELECT u.name AS name FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.room_id = {t}.id AND m.user_id <> :user_id ORDER BY u.id) AS n) AS o WHERE o.cnt > 0), (SELECT name FROM users WHERE id = :user_id)) ELSE COALESCE({t}.name, '') END"
  # Room#messages.count.
  expr :messages_count, type: :i64, sql: "(SELECT COUNT(*) FROM messages WHERE room_id = {t}.id)"
  # Room.original: the first room created (order(:created_at).first), as 1 or 0.
  expr :is_original, type: :i64, sql: "CASE WHEN {t}.id = (SELECT id FROM rooms ORDER BY created_at LIMIT 1) THEN 1 ELSE 0 END"

  # Room#destroy: the messages (each with what Message#destroy takes), the memberships, then the room.
  execute :destroy_room, args: { id: :i64 } do
    where(id: arg(:id)).destroy
  end

  # Room.create!: the id comes from RETURNING. type is the STI class name.
  query :create_room, args: { name: :string, creator_id: :i64, room_type: :string }, returns: :i64 do
    insert(name: arg(:name), creator_id: arg(:creator_id), type: arg(:room_type), returning: :id)
  end

  # Rooms::Direct.create_for({}, users:): no name; Room's `belongs_to :creator, default: -> { Current.user }`.
  query :create_direct_room, args: { creator_id: :i64 }, returns: :i64 do
    insert(creator_id: arg(:creator_id), type: "Rooms::Direct", returning: :id)
  end

  # force_room_type (`@room.becomes!(Rooms::Closed)`, so an open room saved here turns closed, and the other way round)
  # and `@room.update! room_params`; updated_at moves only when the name or the type changed.
  execute :update_closed_room, args: { room_id: :i64, name: :string } do
    where(id: arg(:room_id)).update(name: arg(:name), type: "Rooms::Closed")
  end

  execute :update_open_room, args: { room_id: :i64, name: :string } do
    where(id: arg(:room_id)).update(name: arg(:name), type: "Rooms::Open")
  end

  # The room a message is in, touched (Message's `belongs_to :room, touch: true`).
  execute :touch_message_room, args: { message_id: :i64 } do
    where(id: Message.where(id: arg(:message_id)).select(:room_id)).touch
  end

  execute :touch_user_message_rooms, args: { user_id: :i64 } do
    where(id: Message.where(creator_id: arg(:user_id)).select(:room_id)).touch
  end

  scope :opens, -> { where(type: "Rooms::Open") }
  scope :closeds, -> { where(type: "Rooms::Closed") }
  scope :directs, -> { where(type: "Rooms::Direct") }
  scope :without_directs, -> { where_not(type: "Rooms::Direct") }

  # A room as the sidebar and the room page need it. rooms.name is NULL for a direct room, so the queries fill it in.
  record :Room do
    field :id, :i64
    field :name, :string
  end

  # --- rooms and messages (rooms_controller.rb, messages_controller.rb, message/pagination.rb) -----------------------

  # Current.user.rooms.find_by(id:): only a room the user has a membership in (any involvement).
  query :room_for_user, args: { id: :i64, user_id: :i64 }, returns: :Room? do
    joins(:memberships).where(id: arg(:id), memberships: { user_id: arg(:user_id) }).select(:id, name: coalesce(:name, ""))
  end

  # The room as the cable and the broadcasts name it: Rooms::Open, Rooms::Closed or Rooms::Direct is the STI class in the
  # room's Global ID (turbo_stream_from @room, :messages and TypingNotificationsChannel's stream_for @room). Same membership
  # rule as room_for_user (Current.user.rooms.find_by).
  record :RoomClass do
    field :id, :i64
    field :class_name, :string
  end

  # The room as the cable names it.
  query :room_class_for_user, args: { id: :i64, user_id: :i64 }, returns: :RoomClass? do
    joins(:memberships).where(id: arg(:id), memberships: { user_id: arg(:user_id) }).select(:id, class_name: :type)
  end

  # room.memberships.pluck(:user_id): who Message::Broadcasts#broadcast_unread_room tells.
  record :RoomMember do
    field :user_id, :i64
  end

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

  query :room_page, args: { id: :i64, user_id: :i64 }, returns: :RoomPage? do
    joins(:memberships).where(id: arg(:id), memberships: { user_id: arg(:user_id) })
      .select(id: :id, label: expr(:room_label_for, user_id: arg(:user_id)), kind: expr(:room_kind), updated_ms: expr(:updated_ms),
              message_count: expr(:messages_count), is_original: expr(:is_original))
  end

  # layouts/application's body_classes: "admin" for an administrator, "account-has-logo" when the account has a logo.
  record :BodyFlags do
    field :admin, :i64
    field :logo, :i64
    field :title, :string
    field :version, :string
  end

  # The query (body_flags) is in models/user.axum.rb.

  # WelcomeController#show: where "/" goes when the last_room cookie names no room the user is in. Its
  # last_room_visited falls back to Current.user.rooms.original (order(:created_at).first), not the first
  # membership; the sign-in redirect lands there and that visit sets the last_room cookie. Also
  # TrackedRoomVisit#default_room, the searches page's fallback.
  query :first_room_id, args: { user_id: :i64 }, returns: :i64? do
    joins(:memberships).where(memberships: { user_id: arg(:user_id) }).order(:created_at).pick(:id)
  end


  # --- sidebar (users/sidebars_controller.rb): visible memberships, directs apart from the shared rooms --------------

  # The visible memberships that are not direct rooms, in with_ordered_room order (the record is in models/sidebar.axum.rb).
  query :sidebar_shared_rooms, args: { user_id: :i64 }, returns: list(:SidebarRoom) do
    joins(:memberships).where(memberships: { user_id: arg(:user_id) }).where_not(memberships: { involvement: "invisible" })
      .without_directs
      .select(:id, name: coalesce(:name, ""), kind: expr(:room_kind), unread: expr(:unread_marker, :memberships))
      .order(expr(:lower_name), col(:memberships, :id))
  end

  # RoomsController#index: `redirect_to room_url(Current.user.rooms.last)`, the user's room with the highest id.
  query :last_room_of, args: { user_id: :i64 }, returns: :i64? do
    joins(:memberships).where(memberships: { user_id: arg(:user_id) }).order(id: :desc).pick(:id)
  end

  # Rooms::{Opens,Closeds,Directs}Controller#set_room (the record is in models/room_form.axum.rb): a room the user is in.
  query :room_form_room, args: { id: :i64, user_id: :i64 }, returns: :RoomFormRoom? do
    joins(:memberships).where(id: arg(:id), memberships: { user_id: arg(:user_id) })
      .select(:id, :creator_id, name: coalesce(:name, ""), kind: expr(:room_kind))
  end

  # Accounts::BotsController: a bot's rooms that are not direct (the record is in models/account.axum.rb).
  query :account_bot_rooms, args: { id: :i64 }, returns: list(:AccountBotRoom) do
    joins(:memberships).where(memberships: { user_id: arg(:id) }).without_directs.select(:id, name: coalesce(:name, "")).order(name: :nocase)
  end

  # Rooms::Open.create_for(room_params, users: Current.user): the room, the creator's membership and the after_save_commit
  # grant to every active user, in one transaction. The new room's id.
  def create_open_room(name, creator_id)
    transaction do
      id = create_room(name: name, creator_id: creator_id, room_type: "Rooms::Open")
      grant_room_member(room_id: id, user_id: creator_id)
      grant_room_to_active_users(room_id: id)
      id
    end
  end

  # Rooms::Closed.create_for(room_params, users: ...): the room and a membership for each checked person (an unknown id
  # grants nothing), in one transaction. The new room's id.
  def create_closed_room(name, creator_id, ids)
    transaction do
      id = create_room(name: name, creator_id: creator_id, room_type: "Rooms::Closed")
      grant_room_members(room_id: id, ids: ids)
      id
    end
  end

  # Rooms::Direct.find_or_create_for(users): the room the people already share, else a new one with a membership for each
  # of them, in one transaction. The room's id.
  def find_or_create_direct_room(ids, creator_id)
    found = direct_room_for(ids: ids)
    room_id = if found.nil?
      transaction do
        id = create_direct_room(creator_id: creator_id)
        grant_direct_members(room_id: id, ids: ids)
        id
      end
    else
      found
    end
    room_id
  end

  # `room.update!(name:, users:)` of a closed room: the checked people granted, the others revoked, the name saved, in
  # one transaction. The rows the name update changed: 1, or 0 when the room is gone.
  def revise_closed_room(room_id, ids, name)
    transaction do
      grant_room_members(room_id: room_id, ids: ids)
      revoke_room_members(room_id: room_id, ids: ids)
      update_closed_room(room_id: room_id, name: name)
    end
  end

  # `room.update!(name:)` of an open room (Rooms::Open's grant to every active user follows in the action). The rows the
  # update changed: 1, or 0 when the room is gone.
  def revise_open_room(room_id, name)
    transaction do
      update_open_room(room_id: room_id, name: name)
    end
  end

  # `room.destroy`: the room goes with its memberships, messages and what hangs off them, in one transaction.
  def remove_room(room_id)
    transaction do
      destroy_room(id: room_id)
    end
  end
end
