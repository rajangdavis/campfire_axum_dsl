model :User, table: :users do
  # app/models/user.rb, with its concerns (Bot, Role, Bannable). Not declared: `has_many :reachable_messages, through: :rooms,
  # source: :messages` (a through of a through), the `ordered` and `filtered_by` scopes (raw SQL), and the avatar attachment.
  has_many :memberships, dependent: :delete_all
  has_many :rooms, through: :memberships
  has_many :messages, dependent: :destroy, foreign_key: :creator_id
  has_many :push_subscriptions, model: "Push::Subscription", dependent: :delete_all
  has_many :boosts, dependent: :destroy, foreign_key: :booster_id
  has_many :searches, dependent: :delete_all
  has_many :sessions, dependent: :destroy
  has_many :bans, dependent: :destroy
  has_one :webhook, model: :Webhook, dependent: :delete_all # Rails: dependent: :delete, the one DELETE
  # has_one_attached :avatar derives has_one :avatar_attachment and :avatar_blob, `attached(:avatar)` and the statements `attach` runs.
  has_one_attached :avatar
  has_one :blob, through: :avatar_attachment

  # enum :status, %i[ active deactivated banned ] (0, 1, 2) and enum :role, %i[ member administrator bot ] (0, 1, 2):
  # a scope for each value and its `not_` twin, as Rails defines them.
  scope :active, -> { where(status: 0) }
  scope :deactivated, -> { where(status: 1) }
  scope :banned, -> { where(status: 2) }
  scope :not_active, -> { where_not(status: 0) }
  scope :not_deactivated, -> { where_not(status: 1) }
  scope :not_banned, -> { where_not(status: 2) }
  scope :member, -> { where(role: 0) }
  scope :administrator, -> { where(role: 1) }
  scope :bot, -> { where(role: 2) }
  scope :not_member, -> { where_not(role: 0) }
  scope :not_administrator, -> { where_not(role: 1) }
  scope :not_bot, -> { where_not(role: 2) }
  # User::Bot
  scope :active_bots, -> { active.where(role: 2) }
  scope :without_bots, -> { where_not(role: 2) }

  # --- exprs: the SQL the relations below select (`expr(:name)`; `expr(:name, :creator)` from a model that joins users) ---------
  # `{t}` is the users table. `updated_at_number` is the concern Timestamps, `lower_name` the concern Named.
  include :Timestamps
  include :Named

  # User#title: the name, with the bio after a dash when there is one.
  expr :user_title, type: :string,
       sql: "CASE WHEN COALESCE({t}.bio, '') = '' THEN {t}.name ELSE {t}.name || ' – ' || {t}.bio END"
  # ApplicationHelper#body_classes for a signed-in page: "admin" for an administrator, "account-has-logo" when the account has one.
  expr :body_classes, type: :string,
       sql: "trim(CASE WHEN {t}.role = 1 THEN 'admin' ELSE '' END || ' ' || CASE WHEN EXISTS (SELECT 1 FROM active_storage_attachments WHERE record_type = 'Account' AND name = 'logo') THEN 'account-has-logo' ELSE '' END)"
  # AccountUser#is_current: the row is the signed-in user (`user == Current.user`), for the disabled role box and the profile link.
  expr :is_current, type: :bool, args: { user_id: :i64 }, sql: "CASE WHEN {t}.id = :user_id THEN 1 ELSE 0 END"
  # Accounts' people list: active people, and banned ones too when the viewer can administer (`User.active` plus `User.banned` for an administrator).
  expr :visible_status, type: :bool, args: { include_banned: :i64 },
       sql: "{t}.status = 0 OR (:include_banned = 1 AND {t}.status = 2)"
  # User#active? (enum :status, %i[ active deactivated banned ]).
  expr :is_active, type: :bool, sql: "CASE WHEN {t}.status = 0 THEN 1 ELSE 0 END"
  # User#banned?.
  expr :is_banned, type: :bool, sql: "CASE WHEN {t}.status = 2 THEN 1 ELSE 0 END"
  # User#administrator? (enum :role, %i[ member administrator bot ]).
  expr :is_administrator, type: :bool, sql: "CASE WHEN {t}.role = 1 THEN 1 ELSE 0 END"
  # User#bot_key: "#{id}-#{bot_token}".
  expr :bot_key, type: :string, sql: "CAST({t}.id AS TEXT) || '-' || COALESCE({t}.bot_token, '')"
  # User#webhook&.url: the bot's webhook address, '' without one.
  expr :webhook_url, type: :string, sql: "COALESCE((SELECT w.url FROM webhooks w WHERE w.user_id = {t}.id LIMIT 1), '')"
  # User#role (enum :role, %i[ member administrator bot ]) by name.
  expr :role_name, type: :string,
       sql: "CASE COALESCE({t}.role, 0) WHEN 1 THEN 'administrator' WHEN 2 THEN 'bot' ELSE 'member' END"
  # Message#mentionees: the user is among the body's Action Text attachables.
  expr :mentioned_in, type: :bool, args: { body: :string },
       sql: "{t}.id IN (SELECT value FROM json_each(action_text_attachable_ids(:body, 'User')))"
  # MessagesController#deliver_webhooks_to_bots: `@room.direct? ? @room.users.active_bots : @message.mentionees.active_bots`.
  expr :webhook_recipient, type: :bool, args: { direct: :i64, body: :string },
       sql: ":direct = 1 OR {t}.id IN (SELECT value FROM json_each(action_text_attachable_ids(:body, 'User')))"
  # User#webhook (has_one: the first by id) &.url, '' without one.
  expr :first_webhook_url, type: :string,
       sql: "COALESCE((SELECT w.url FROM webhooks w WHERE w.user_id = {t}.id ORDER BY w.id LIMIT 1), '')"
  # `room.users.many? ? room.users.without(user) : room.users`: a member of the room other than the viewer, or the viewer when alone.
  expr :without_viewer_unless_alone, type: :bool, args: { user_id: :i64, room_id: :i64 },
       sql: "{t}.id <> :user_id OR (SELECT COUNT(*) FROM memberships m2 WHERE m2.room_id = :room_id) = 1"

  # --- rows -----------------------------------------------------------------------------------------------------

  record :User do
    field :id, :i64
    field :name, :string
    field :password_digest, :string
  end

  # --- sessions (app/controllers/sessions_controller.rb, concerns/authentication.rb) ------------------------------

  # User.active.authenticate_by: status 0 is `active` (app/models/user.rb: enum :status, %i[ active deactivated banned ]).
  query :active_user_by_email, args: { email: :string }, returns: :User? do
    where(email_address: arg(:email), status: 0).select(:id, :name, password_digest: coalesce(:password_digest, ""))
  end

  # `users.email_address`'s unique index: UsersController#create answers its RecordNotUnique rescue when this is not 0.
  # The app does not normalize addresses, and the index is plain email_address, so neither does this.
  query :user_email_taken, args: { email: :string }, returns: :i64 do
    where(email_address: arg(:email)).count
  end

  # User.active.find_by_transfer_id: `find_signed(id, purpose: :transfer)` then a status 0 lookup
  # (app/controllers/sessions/transfers_controller.rb:8).
  query :active_user_by_id, args: { id: :i64 }, returns: :User? do
    where(id: arg(:id), status: 0).select(:id, :name, password_digest: coalesce(:password_digest, ""))
  end

  query :user_for_session, args: { token: :string }, returns: :User? do
    joins(:sessions).where(sessions: { token: arg(:token) }, status: 0).select(:id, :name, password_digest: coalesce(:password_digest, ""))
  end

  query :active_user_role, args: { id: :i64 }, returns: :i64? do
    where(id: arg(:id), status: 0).pick(:role)
  end

  # `@user.update(role:)`: updated_at (the avatar's `?v=`) moves only when the role changed.
  execute :set_user_role, args: { id: :i64, role: :i64 } do
    where(id: arg(:id)).update(role: arg(:role))
  end

  # A bot's `update!(name:, avatar:)`: updated_at moves when the name changed (the avatar's own touch moves it when one came).
  execute :rename_bot, args: { id: :i64, name: :string } do
    where(id: arg(:id)).update(name: arg(:name))
  end

  # User#deactivate, in its transaction: memberships outside direct rooms, push subscriptions, searches and sessions go,
  # then status deactivated (1) and the address `gsub(/@/, "-deactivated-#{SecureRandom.uuid}@")` (a v4 UUID for every @).
  execute :deactivate_user_row, args: { id: :i64 }, sql: <<~SQL
    WITH uuid(v) AS (
      SELECT lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))), 2) || '-'
             || substr('89ab', (abs(random()) % 4) + 1, 1) || substr(lower(hex(randomblob(2))), 2) || '-' || lower(hex(randomblob(6)))
    )
    UPDATE users SET status = 1, updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now'),
      email_address = replace(email_address, '@', '-deactivated-' || (SELECT v FROM uuid) || '@')
    WHERE id = :id
  SQL

  # AccountsController#edit's paging count: account_users.without_bots (banned people too for an administrator).
  query :account_people_count, args: { include_banned: :i64 }, returns: :i64 do
    without_bots.where(expr(:visible_status, include_banned: arg(:include_banned))).count
  end

  # AccountsController#edit: `account_users.ordered.without_bots`, split by role. The viewer sees banned people
  # only when they can administer the account; the row knows whether it is the current user for its disabled
  # role checkbox and its profile link.
  query :account_users, args: { role: :i64, include_banned: :i64, user_id: :i64 }, returns: list(:AccountUser) do
    where(role: arg(:role)).where(expr(:visible_status, include_banned: arg(:include_banned)))
      .select(id: :id, name: :name, title: coalesce(expr(:user_title), ""), role: :role, status: :status,
              active: expr(:is_active), banned: expr(:is_banned), administrator: expr(:is_administrator),
              avatar_version: expr(:updated_at_number), is_current: expr(:is_current, user_id: arg(:user_id)))
      .order(expr(:lower_name))
  end

  # A bot as Accounts::BotsController shows it: `User.active_bots.ordered` with the avatar attachment and its blob (left
  # joined: a bot may have no avatar), the bot key and the webhook's address.
  scope :bot_rows, -> {
    left_joins(:blob).select(
      id: :id, name: :name, title: coalesce(expr(:user_title), ""), avatar_version: expr(:updated_at_number),
      avatar_attached: attached(:avatar), avatar_blob_id: col(:avatar_attachment, :blob_id),
      avatar_filename: coalesce(col(:blob, :filename), ""), bot_key: expr(:bot_key), webhook_url: expr(:webhook_url)
    )
  }

  query :account_bots, args: {}, returns: list(:AccountBot) do
    active_bots.bot_rows.order(expr(:lower_name))
  end

  query :account_bot, args: { id: :i64 }, returns: :AccountBot? do
    active_bots.bot_rows.where(id: arg(:id))
  end

  # One page of Accounts::UsersController#index: `User.active.ordered.without_bots`, 500 a page.
  query :account_users_page, args: { offset: :i64, user_id: :i64 }, returns: list(:AccountUser) do
    active.without_bots
      .select(id: :id, name: :name, title: coalesce(expr(:user_title), ""), role: :role, status: :status, active: true, banned: false,
              administrator: expr(:is_administrator), avatar_version: expr(:updated_at_number), is_current: expr(:is_current, user_id: arg(:user_id)))
      .order(expr(:lower_name)).limit(500).offset(arg(:offset))
  end

  # Autocompletable::UsersController#index without a room: active users whose name matches, 20 at a time.
  query :autocomplete_all_users, args: { pattern: :string }, returns: list(:AutocompleteUser) do
    active.where(like(:name, arg(:pattern))).select(:id, :name, title: expr(:user_title), avatar_version: expr(:updated_at_number))
      .order(name: :nocase).limit(20)
  end

  # Autocompletable::UsersController#index with a room: active users whose name matches `pattern` who are in `room_id`,
  # which the current user must be in too, in Rails' `LOWER(name)` order, 20 at a time.
  query :autocomplete_room_users, args: { user_id: :i64, room_id: :i64, pattern: :string }, returns: list(:AutocompleteUser) do
    joins(:memberships).where(status: 0, memberships: { room_id: arg(:room_id) }).where(like(:name, arg(:pattern)))
      .where_exists(:memberships, room_id: arg(:room_id), user_id: arg(:user_id))
      .select(:id, :name, title: expr(:user_title), avatar_version: expr(:updated_at_number))
      .order(expr(:lower_name)).limit(20)
  end

  # The room forms' user list: User.active.ordered.
  query :active_form_users, args: {}, returns: list(:RoomFormUser) do
    active.select(:id, :name, title: expr(:user_title), version: expr(:updated_at_number), value: expr(:lower_name))
      .order(name: :nocase)
  end

  # A closed room's edit page partitions User.active.ordered by membership: the active users who are not members of the room.
  query :room_form_unselected_users, args: { room_id: :i64 }, returns: list(:RoomFormUser) do
    active.where_not_exists(:memberships, room_id: arg(:room_id))
      .select(:id, :name, title: expr(:user_title), version: expr(:updated_at_number), value: expr(:lower_name))
      .order(expr(:lower_name))
  end

  # A closed room's edit page: the active users who are members of the room.
  query :room_form_selected_users, args: { room_id: :i64 }, returns: list(:RoomFormUser) do
    joins(:memberships).where(status: 0, memberships: { room_id: arg(:room_id) })
      .select(:id, :name, title: expr(:user_title), version: expr(:updated_at_number), value: expr(:lower_name))
      .order(name: :nocase)
  end

  # Rooms::DirectsController#edit's @room.users.without(Current.user): the reference lists the other members by user id
  # (the same order room_display_name uses), so the group ping reads Jason, Kevin, JZ. `users.many? ? users.without(Current.user) : users`
  # keeps the current user only in a one-person direct room.
  query :room_form_members, args: { room_id: :i64, user_id: :i64 }, returns: list(:RoomFormUser) do
    joins(:memberships).where(memberships: { room_id: arg(:room_id) })
      .where(expr(:without_viewer_unless_alone, user_id: arg(:user_id), room_id: arg(:room_id)))
      .select(:id, :name, title: expr(:user_title), version: expr(:updated_at_number), value: expr(:lower_name))
      .order(:id)
  end

  query :active_people_count, args: {}, returns: :i64 do

    where(status: 0).where_not(role: 2).count
  end

  query :user_exists, args: { id: :i64 }, returns: :i64? do
    where(id: arg(:id)).pick(:id)
  end

  # `banned!` / `active!`: the status enum, and updated_at when it changed.
  execute :set_user_status, args: { user_id: :i64, status: :i64 } do
    where(id: arg(:user_id)).update(status: arg(:status))
  end

  # RemoveBannedContentJob (User#remove_banned_content): each of the person's messages destroyed and broadcast_remove'd.
  # The messages are read first, for the broadcasts; Message#destroy's dependents go with them as in DELETE
  # /rooms/:id/messages/:message_id, and each message touches its room.
  record :BannedMessage do
    field :param, :string
    field :room_id, :i64
    field :room_class, :string
  end

  execute :touch_user, args: { user_id: :i64 } do
    where(id: arg(:user_id)).touch
  end

  # User#avatar.destroy as one step, for the avatar whose blob id is given: the user is touched (the attachment's
  # `touch: true`), then the blob goes with its variant records, their image attachments and blobs. The rows the last
  # delete changed: 1 when the blob was removed.
  def purge_user_avatar(user_id, blob)
    variants = variant_blob_ids(blob_id: blob)
    transaction do
      touch_user(user_id: user_id)
      detach_variant_images(blob_id: blob)
      delete_variant_records(blob_id: blob)
      delete_blobs(ids: variants)
      detach_user_avatar(user_id: user_id)
      delete_blob(id: blob)
    end
  end

  # User#ban: the person's cable connections close, then in one transaction their session IPs are banned, their
  # sessions deleted, their messages removed with the files attached to them (RemoveBannedContentJob, run here in the
  # request) and the row is marked banned. The rows the status update changed: 1, or 0 when the person is gone.
  def ban_user(id)
    purged = purge_set(ids: creator_message_blob_ids(user_id: id))
    close_remote_connections(id, reconnect: false)
    transaction do
      ban_session_ips(user_id: id)
      delete_user_sessions(user_id: id)
      touch_user_message_rooms(user_id: id)
      destroy_user_messages(user_id: id)
      purge_blob_dependents(ids: purged)
      purge_blob_variant_records(ids: purged)
      purge_blobs(ids: purged)
      set_user_status(user_id: id, status: 2)
    end
  end

  # User#unban: the bans go and the status is active again. The rows the status update changed.
  def unban_user(id)
    transaction do
      delete_user_bans(user_id: id)
      set_user_status(user_id: id, status: 0)
    end
  end

  # `@user.update user_params` for the profile page's three forms, each sending only its own keys: a key that is
  # absent is left as it is, a blank password is ignored (has_secure_password), and updated_at moves only when a value
  # changed or an avatar was attached. The rows the update matched.
  def save_profile(user_id, new_name, new_email, new_password, new_bio, avatar)
    password = new_password || ""
    digest = password.empty? ? "" : Bcrypt.hash(password)
    has_name = new_name.nil? ? 0 : 1
    has_email = new_email.nil? ? 0 : 1
    has_bio = new_bio.nil? ? 0 : 1
    has_password = password.empty? ? 0 : 1
    name = new_name || ""
    email = new_email || ""
    bio = new_bio || ""
    # The file is written before the transaction; its blob carries the metadata Rails leaves once AnalyzeJob has run.
    stored = avatar&.store_file(setting(:storage))
    transaction do
      attach(:avatar, user_id, stored)
      update_profile(id: user_id, has_name: has_name, name: name, has_email: has_email, email: email, has_bio: has_bio, bio: bio, has_password: has_password, digest: digest)
    end
  end

  # UsersController#create: `User.create!(user_params)` (a member, with an avatar when one came, granted every open
  # room by its after_create_commit) and start_new_session_for(user), in one transaction. The rows the session insert
  # changed: 1 when the person is signed in.
  def sign_up_user(name, email, password, avatar, token, ip, agent)
    digest = Bcrypt.hash(password)
    stored = avatar&.store_file(setting(:storage))
    transaction do
      id = create_user(name: name, email: email, digest: digest)
      grant_open_rooms_to(user_id: id)
      attach(:avatar, id, stored, fresh: true)
      start_session(token: token, user_id: id, ip: ip, agent: agent)
    end
  end

  # Current.user as the form fills it in; avatar_attached says whether an avatar blob is attached (the delete button).
  record :ProfileUser do
    field :name, :string
    field :email, :string
    field :bio, :string
    field :version, :string
    field :avatar_attached, :bool
  end

  query :profile_user, args: { id: :i64 }, returns: :ProfileUser? do
    where(id: arg(:id)).select(:name, email: coalesce(:email_address, ""), bio: coalesce(:bio, ""),
                               version: expr(:updated_at_number), avatar_attached: attached(:avatar))
  end

  # One row of `Current.user.memberships.with_ordered_room` (LOWER(rooms.name), then the room), the shared rooms or the
  # direct ones. label is room_display_name(room, for_user:) (a direct room is named after the other people in it);
  # next_involvement and text are Rooms::InvolvementsHelper's, the bell flags choose the icon.
  record :ProfileMembership do
    field :room_id, :i64
    field :kind, :string
    field :label, :string
    field :involvement, :string
    field :next_involvement, :string
    field :text, :string
    field :bell_mentions, :bool
    field :bell_everything, :bool
    field :bell_nothing, :bool
    field :bell_invisible, :bool
  end

  query :profile_memberships, args: { user_id: :i64, direct: :i64 }, returns: list(:ProfileMembership), sql: <<~SQL
    SELECT room_id, kind, label, involvement,
           CASE WHEN kind = 'direct' THEN CASE WHEN involvement = 'everything' THEN 'nothing' ELSE 'everything' END
                ELSE CASE involvement WHEN 'mentions' THEN 'everything' WHEN 'everything' THEN 'nothing' WHEN 'nothing' THEN 'invisible' ELSE 'mentions' END END AS next_involvement,
           CASE involvement WHEN 'mentions' THEN 'Notifying about @ mentions' WHEN 'everything' THEN 'Notifying about all messages'
                WHEN 'nothing' THEN 'Notifications are off' ELSE 'Notifications are off and room invisible in sidebar' END AS text,
           involvement = 'mentions' AS bell_mentions, involvement = 'everything' AS bell_everything,
           involvement = 'nothing' AS bell_nothing, involvement = 'invisible' AS bell_invisible
    FROM (
      SELECT r.id AS room_id,
             CASE r.type WHEN 'Rooms::Open' THEN 'open' WHEN 'Rooms::Closed' THEN 'closed' ELSE 'direct' END AS kind,
             CASE WHEN r.type = 'Rooms::Direct' THEN COALESCE(
               (SELECT CASE WHEN o.cnt = 1 THEN o.s
                            ELSE substr(o.s, 1, length(o.s) - length(o.last_name) - 2)
                                 || CASE o.cnt WHEN 2 THEN ' and ' ELSE ', and ' END || o.last_name END
                FROM (SELECT COUNT(*) AS cnt, group_concat(n.name, ', ') AS s,
                             (SELECT u2.name FROM memberships m2 JOIN users u2 ON u2.id = m2.user_id
                              WHERE m2.room_id = r.id AND m2.user_id <> :user_id ORDER BY u2.id DESC LIMIT 1) AS last_name
                      FROM (SELECT u.name AS name FROM memberships m3 JOIN users u ON u.id = m3.user_id
                            WHERE m3.room_id = r.id AND m3.user_id <> :user_id ORDER BY u.id) AS n) AS o
                WHERE o.cnt > 0),
               (SELECT name FROM users WHERE id = :user_id))
             ELSE COALESCE(r.name, '') END AS label,
             COALESCE(m.involvement, 'mentions') AS involvement,
             r.name AS sort_name, m.id AS membership_id
      FROM memberships m JOIN rooms r ON r.id = m.room_id
      WHERE m.user_id = :user_id AND (r.type = 'Rooms::Direct') = (:direct = 1)
    )
    ORDER BY LOWER(sort_name), membership_id
  SQL

  execute :update_profile, args: { id: :i64, has_name: :i64, name: :string, has_email: :i64, email: :string, has_bio: :i64, bio: :string, has_password: :i64, digest: :string }, sql: <<~SQL
    UPDATE users SET
      updated_at = CASE WHEN (:has_name = 1 AND name <> :name) OR (:has_email = 1 AND COALESCE(email_address, '') <> :email)
                          OR (:has_bio = 1 AND COALESCE(bio, '') <> :bio) OR :has_password = 1
                        THEN strftime('%Y-%m-%d %H:%M:%f', 'now') ELSE updated_at END,
      name = CASE WHEN :has_name = 1 THEN :name ELSE name END,
      email_address = CASE WHEN :has_email = 1 THEN :email ELSE email_address END,
      bio = CASE WHEN :has_bio = 1 THEN :bio ELSE bio END,
      password_digest = CASE WHEN :has_password = 1 THEN :digest ELSE password_digest END
    WHERE id = :id
  SQL

  # has_secure_password stores the BCrypt digest (cost 12, Bcrypt.hash); role 0 is member and status 0 active (the defaults).
  query :create_user, args: { name: :string, email: :string, digest: :string }, returns: :i64 do
    insert(name: arg(:name), email_address: arg(:email), password_digest: arg(:digest), role: 0, status: 0, returning: :id)
  end

  # The administrator: `User.new(user_params.merge(role: :administrator))`, role 1, status 0 (active).
  query :create_administrator, args: { name: :string, email: :string, digest: :string }, returns: :i64 do
    insert(name: arg(:name), email_address: arg(:email), password_digest: arg(:digest), role: 1, status: 0, returning: :id)
  end

  # The user a page is about: role 2 is a bot and status 0 is active, 1 deactivated, 2 banned (user.rb enums).
  # version is User#updated_at.to_fs(:number), the `?v=` fresh_user_avatar_path writes.
  record :UserPageRow do
    field :id, :i64
    field :name, :string
    field :bio, :string
    field :email, :string
    field :role, :i64
    field :status, :i64
    field :version, :string
  end

  query :user_page_row, args: { id: :i64 }, returns: :UserPageRow? do
    where(id: arg(:id)).select(:id, :name, :role, :status, bio: coalesce(:bio, ""), email: coalesce(:email_address, ""),
                               version: expr(:updated_at_number))
  end

  # User#deactivate: the person's cable connections close without a reconnect, then their memberships, push

  # subscriptions, searches and sessions go and the row is marked deactivated. The rows changed: 1, or 0 when the
  # person was already gone.
  def deactivate_user(id)
    close_remote_connections(id, reconnect: false)
    transaction do
      deactivate_user_memberships(id: id)
      deactivate_user_push_subscriptions(id: id)
      deactivate_user_searches(id: id)
      deactivate_user_sessions(id: id)
      deactivate_user_row(id: id)
    end
  end

  # SessionsController#ensure_user_exists: `redirect_to first_run_url if User.none?`.
  query :user_count, args: {}, returns: :i64 do
    count
  end

  # application_helper.rb body_classes for a signed-in page: "admin" for an administrator, "account-has-logo" when
  # the account has one, space-separated.
  query :sidebar_page_class, args: { user_id: :i64 }, returns: :string? do
    where(id: arg(:user_id)).pick(expr(:body_classes))
  end

  # layouts/application's body_classes: "admin" for an administrator, "account-has-logo" when the account has a logo.
  # The BodyFlags record carries the flags as integers: the :bool exprs fill its :i64 fields (SQLite holds a boolean as 0 or 1).
  query :body_flags, args: { user_id: :i64 }, returns: :BodyFlags? do
    where(id: arg(:user_id)).select(admin: expr(:is_administrator), logo: expr(:logo_attached), title: expr(:user_title), version: expr(:updated_at_number))
  end

  # `action_text_attachable_ids(body, 'User')` (in the mentioned_in expr) is the DSL's SQL function over the body's
  # <action-text-attachment sgid>s (a JSON array of the User ids their GlobalIDs name; a Rails 7 Marshal-era sgid counts,
  # as lib/rails_ext/action_text_attachables.rb tolerates it for users).
  query :message_mentions, args: { body: :string }, returns: list(:MentionRow) do
    where(expr(:mentioned_in, body: arg(:body)))
      .select(id: :id, name: :name, title: expr(:user_title), version: coalesce(expr(:updated_at_number), "")).order(:id)
  end

  # MessagesController#deliver_webhooks_to_bots: `@room.direct? ? @room.users.active_bots : @message.mentionees.active_bots`,
  # the message's creator excepted, each bot that has a webhook (`deliver_webhook_later ... if webhook`), with its bot
  # key (Webhook#room_bot_messages_path) and its webhook's URL (has_one: the first).
  query :webhook_bots, args: { room_id: :i64, creator_id: :i64, body: :string, direct: :i64 }, returns: list(:WebhookBot) do
    joins(:memberships).where(memberships: { room_id: arg(:room_id) }).active_bots.where_not(id: arg(:creator_id))
      .where_exists(:webhook).where(expr(:webhook_recipient, direct: arg(:direct), body: arg(:body)))
      .select(id: :id, name: coalesce(:name, ""), bot_key: expr(:bot_key), url: expr(:first_webhook_url)).order(:id)
  end

  # Authentication behind the bot API and the bots pages: the active bot (role 2, status 0) with this id.
  query :active_bot_id, args: { id: :i64 }, returns: :i64? do
    where(id: arg(:id), role: 2, status: 0).pick(:id)
  end
end
