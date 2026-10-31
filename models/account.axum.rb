
fragment do
  # What the sign-in and join pages read from the account: its name and join code, the logo's cache-busting version
  # (routes.rb `fresh_account_logo`: updated_at.to_fs(:number)), and the first administrator for the help contact
  # (accounts/_help_contact.html.erb: User.administrator.first; role 1 is administrator, '' when there is none).
  record :AccountPage do
    field :id, :i64
    field :name, :string
    field :join_code, :string
    field :logo_version, :string
    field :admin_name, :string
    field :admin_email, :string
  end

  # fresh_account_logo_path: the layout's /account/logo?v= (account.updated_at.to_fs(:number)).
  query :account_logo_version, args: {}, returns: :string?, sql: <<~SQL
    SELECT strftime('%Y%m%d%H%M%S', updated_at) FROM accounts LIMIT 1
  SQL

  # accounts/_invite: Current.account.join_code, for the join link.
  query :account_join_code, args: {}, returns: :string?, sql: <<~SQL
    SELECT join_code FROM accounts LIMIT 1
  SQL

  query :account_page, args: {}, returns: :AccountPage?, sql: <<~SQL
    SELECT a.id AS id, a.name AS name, a.join_code AS join_code,
           strftime('%Y%m%d%H%M%S', a.updated_at) AS logo_version,
           COALESCE((SELECT u.name FROM users u WHERE u.role = 1 ORDER BY u.id LIMIT 1), '') AS admin_name,
           COALESCE((SELECT u.email_address FROM users u WHERE u.role = 1 ORDER BY u.id LIMIT 1), '') AS admin_email
    FROM accounts a LIMIT 1
  SQL

  # AccountsController#edit / CustomStylesController#edit: the account settings that are not in AccountPage.
  # `settings` is a JSON column; a missing key is false, as AccountSettings#[] returns false.
  record :AccountSettings do
    field :restrict_room_creation, :bool
    field :custom_styles, :string
    field :has_logo, :bool
  end

  query :account_settings, args: {}, returns: :AccountSettings?, sql: <<~SQL
    SELECT COALESCE(json_extract(settings, '$.restrict_room_creation_to_administrators'), 0) = 1 AS restrict_room_creation,
           COALESCE(custom_styles, '') AS custom_styles,
           CASE WHEN EXISTS (SELECT 1 FROM active_storage_attachments a WHERE a.record_type = 'Account' AND a.name = 'logo') THEN 1 ELSE 0 END AS has_logo
    FROM accounts LIMIT 1
  SQL

  # AccountsController#edit: `account_users.ordered.without_bots`, split by role. The viewer sees banned people
  # only when they can administer the account; the row knows whether it is the current user for its disabled
  # role checkbox and its profile link.
  record :AccountUser do
    field :id, :i64
    field :name, :string
    field :title, :string
    field :role, :i64
    field :status, :i64
    field :active, :bool
    field :banned, :bool
    field :administrator, :bool
    field :avatar_version, :string
    field :is_current, :bool
  end

  query :account_users, args: { role: :i64, include_banned: :i64, user_id: :i64 }, returns: list(:AccountUser), sql: <<~SQL
    SELECT u.id AS id, u.name AS name,
           COALESCE(CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END, '') AS title,
           u.role AS role, u.status AS status,
           CASE WHEN u.status = 0 THEN 1 ELSE 0 END AS active,
           CASE WHEN u.status = 2 THEN 1 ELSE 0 END AS banned,
           CASE WHEN u.role = 1 THEN 1 ELSE 0 END AS administrator,
           strftime('%Y%m%d%H%M%S', u.updated_at) AS avatar_version,
           CASE WHEN u.id = :user_id THEN 1 ELSE 0 END AS is_current
    FROM users u
    WHERE u.role = :role AND (u.status = 0 OR (:include_banned = 1 AND u.status = 2))
    ORDER BY LOWER(u.name)
  SQL

  # Accounts::BotsController: `User.active_bots.ordered`, with the bot key and its (non-direct) rooms.
  record :AccountBotRoom do
    field :id, :i64
    field :name, :string
  end

  record :AccountBot do
    field :id, :i64
    field :name, :string
    field :title, :string
    field :avatar_version, :string
    field :avatar_attached, :bool
    field :avatar_blob_id, :i64, optional: true
    field :avatar_filename, :string
    field :bot_key, :string
    field :webhook_url, :string
    field :rooms, list(:AccountBotRoom), from: :account_bot_rooms
  end

  query :account_bot_rooms, args: { id: :i64 }, returns: list(:AccountBotRoom), sql: <<~SQL
    SELECT r.id AS id, COALESCE(r.name, '') AS name
    FROM rooms r JOIN memberships m ON m.room_id = r.id
    WHERE m.user_id = :id AND r.type <> 'Rooms::Direct'
    ORDER BY LOWER(r.name)
  SQL

  query :account_bots, args: {}, returns: list(:AccountBot), sql: <<~SQL
    SELECT u.id AS id, u.name AS name,
           COALESCE(CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END, '') AS title,
           strftime('%Y%m%d%H%M%S', u.updated_at) AS avatar_version,
           CASE WHEN a.id IS NULL THEN 0 ELSE 1 END AS avatar_attached,
           a.blob_id AS avatar_blob_id,
           COALESCE(b.filename, '') AS avatar_filename,
           CAST(u.id AS TEXT) || '-' || COALESCE(u.bot_token, '') AS bot_key,
           COALESCE((SELECT w.url FROM webhooks w WHERE w.user_id = u.id LIMIT 1), '') AS webhook_url
    FROM users u
    LEFT JOIN active_storage_attachments a ON a.record_type = 'User' AND a.record_id = u.id AND a.name = 'avatar'
    LEFT JOIN active_storage_blobs b ON b.id = a.blob_id
    WHERE u.role = 2 AND u.status = 0
    ORDER BY LOWER(u.name)
  SQL

  query :account_bot, args: { id: :i64 }, returns: :AccountBot?, sql: <<~SQL
    SELECT u.id AS id, u.name AS name,
           COALESCE(CASE WHEN COALESCE(u.bio, '') = '' THEN u.name ELSE u.name || ' – ' || u.bio END, '') AS title,
           strftime('%Y%m%d%H%M%S', u.updated_at) AS avatar_version,
           CASE WHEN a.id IS NULL THEN 0 ELSE 1 END AS avatar_attached,
           a.blob_id AS avatar_blob_id,
           COALESCE(b.filename, '') AS avatar_filename,
           CAST(u.id AS TEXT) || '-' || COALESCE(u.bot_token, '') AS bot_key,
           COALESCE((SELECT w.url FROM webhooks w WHERE w.user_id = u.id LIMIT 1), '') AS webhook_url
    FROM users u
    LEFT JOIN active_storage_attachments a ON a.record_type = 'User' AND a.record_id = u.id AND a.name = 'avatar'
    LEFT JOIN active_storage_blobs b ON b.id = a.blob_id
    WHERE u.id = :id AND u.role = 2 AND u.status = 0
  SQL
end
