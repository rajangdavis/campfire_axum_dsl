
model :Account, table: :accounts do
  # app/models/account.rb: it declares no association the DSL can say (has_one_attached :logo is name-filtered).

  # `{t}` is the accounts table. `updated_at_number` (the logo version) is the concern Timestamps.
  include :Timestamps

  # User.administrator.first&.name and &.email_address, '' when there is none (accounts/_help_contact.html.erb). They read the users table, not {t}.
  expr :first_administrator_name, type: :string, sql: "COALESCE((SELECT u.name FROM users u WHERE u.role = 1 ORDER BY u.id LIMIT 1), '')"
  expr :first_administrator_email, type: :string, sql: "COALESCE((SELECT u.email_address FROM users u WHERE u.role = 1 ORDER BY u.id LIMIT 1), '')"
  # AccountSettings#restrict_room_creation_to_administrators (has_json): a missing key is false.
  expr :restrict_room_creation, type: :bool, sql: "COALESCE(json_extract({t}.settings, '$.restrict_room_creation_to_administrators'), 0) = 1"

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
  query :account_logo_version, args: {}, returns: :string? do
    pick(expr(:updated_at_number))
  end

  # accounts/_invite: Current.account.join_code, for the join link.
  query :account_join_code, args: {}, returns: :string? do
    pick(:join_code)
  end

  query :account_page, args: {}, returns: :AccountPage? do
    select(:id, :name, :join_code, logo_version: expr(:updated_at_number),
           admin_name: expr(:first_administrator_name), admin_email: expr(:first_administrator_email))
  end

  # AccountsController#edit / CustomStylesController#edit: the account settings that are not in AccountPage.
  # `settings` is a JSON column; a missing key is false, as AccountSettings#[] returns false.
  record :AccountSettings do
    field :restrict_room_creation, :bool
    field :custom_styles, :string
    field :has_logo, :bool
  end

  # application_helper.rb account_logo_body_class: "account-has-logo" when the account's logo is attached, else "".
  def account_logo_class
    account_logo_attached ? "account-has-logo" : ""
  end

  # application_helper.rb custom_styles_tag: `Current.account&.custom_styles` as a `<style data-turbo-track="reload">`, written
  # whenever the column is not NULL (an empty string included: Ruby's "" is truthy). nil without an account.
  query :account_custom_styles, args: {}, returns: :string? do
    where_not(custom_styles: nil).pick(:custom_styles)
  end

  query :account_settings, args: {}, returns: :AccountSettings? do
    select(restrict_room_creation: expr(:restrict_room_creation), custom_styles: coalesce(:custom_styles, ""), has_logo: expr(:logo_attached))
  end

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

  # The queries are in models/user.axum.rb (account_users, account_bots, account_bot): they read the users table.

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

  # `@account.update!(name:)`: updated_at moves only when the name changed (the logo's `?v=` is the account's updated_at).
  # Every save also writes has_json's default settings when the column is NULL.
  execute :rename_account, args: { name: :string }, sql: <<~SQL
    UPDATE accounts SET
      updated_at = CASE WHEN name <> :name THEN strftime('%Y-%m-%d %H:%M:%f', 'now') ELSE updated_at END,
      settings = COALESCE(settings, '{"restrict_room_creation_to_administrators":false}'),
      name = :name
  SQL

  # has_json's boolean (ActiveModel's cast: "false", "0", "f" and "off" are false), merged into the stored settings;
  # updated_at moves only when the value changed.
  execute :set_restrict_room_creation, args: { value: :i64 }, sql: <<~SQL
    UPDATE accounts SET
      updated_at = CASE WHEN COALESCE(json_extract(settings, '$.restrict_room_creation_to_administrators'), 0) <> :value
                        THEN strftime('%Y-%m-%d %H:%M:%f', 'now') ELSE updated_at END,
      settings = json_set(COALESCE(settings, '{"restrict_room_creation_to_administrators":false}'),
                          '$.restrict_room_creation_to_administrators', json(CASE WHEN :value = 1 THEN 'true' ELSE 'false' END))
  SQL

  # Still guarded here: it is the transaction's last statement, and a transaction ends in a statement call, not an `if`.
  execute :touch_account_for_new_logo, args: { key: :string }, sql: <<~SQL
    UPDATE accounts SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now'),
      settings = COALESCE(settings, '{"restrict_room_creation_to_administrators":false}')
    WHERE :key <> ''
  SQL

  # `@account.update!(account_params)` for the three account forms, each of which sends one key: the name when it came,
  # the room-creation switch when it came (Rails' boolean cast: "false", "0", "f" and "off" are false), and a new logo
  # when a file came, replacing the old one (its blob, variant records, their image attachments and blobs go first).
  # One transaction.
  def update_account(name, restrict, logo)
    renaming = !name.nil?
    new_name = name || ""
    switching = !restrict.nil?
    switch = restrict || ""
    restricted = switch == "false" || switch == "0" || switch == "f" || switch == "off" ? 0 : 1
    file_name = logo&.filename || ""
    file_type = logo&.content_type || ""
    file_size = logo&.size || 0
    file_checksum = logo&.checksum || ""
    file_metadata = logo&.metadata || ""
    replacing = !logo.nil?
    key = if logo.nil?
      ""
    else
      logo.store(setting(:storage))
    end
    has_key = key != ""
    old_logo = account_logo_blob_id || 0
    old_variants = replacing ? variant_blob_ids(blob_id: old_logo) : ""
    transaction do
      if renaming
        rename_account(name: new_name)
      end
      if switching
        set_restrict_room_creation(value: restricted)
      end
      if replacing
        detach_variant_images(blob_id: old_logo)
      end
      if replacing
        delete_variant_records(blob_id: old_logo)
      end
      if replacing
        delete_blobs(ids: old_variants)
      end
      if replacing
        detach_account_logo
      end
      if replacing
        delete_blob(id: old_logo)
      end
      if has_key
        insert_blob(key: key, filename: file_name, content_type: file_type, metadata: file_metadata, byte_size: file_size, checksum: file_checksum)
        attach_account_logo(key: key)
      end
      touch_account_for_new_logo(key: key)
    end
  end

  # `@account.update!(custom_styles:)`: updated_at (the logo's `?v=`) moves only when the CSS changed.
  execute :update_custom_styles, args: { css: :string }, sql: <<~SQL
    UPDATE accounts SET
      updated_at = CASE WHEN custom_styles IS NULL OR custom_styles <> :css THEN strftime('%Y-%m-%d %H:%M:%f', 'now') ELSE updated_at END,
      settings = COALESCE(settings, '{"restrict_room_creation_to_administrators":false}'),
      custom_styles = :css
  SQL

  # Account::Joinable#reset_join_code: `update! join_code: generate_join_code`, SecureRandom.alphanumeric(12) in three
  # groups of four (the alphabet of FirstRun's account, controllers/first_runs.axum.rb).
  execute :reset_join_code, args: {}, sql: <<~SQL
    WITH RECURSIVE pick(n, code) AS (
      SELECT 0, ''
      UNION ALL
      SELECT n + 1, code || CASE WHEN n IN (4, 8) THEN '-' ELSE '' END ||
             substr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789', (abs(random()) % 62) + 1, 1)
      FROM pick WHERE n < 12
    )
    UPDATE accounts SET join_code = (SELECT code FROM pick WHERE n = 12), settings = COALESCE(settings, '{"restrict_room_creation_to_administrators":false}'), updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now')
  SQL

  # `Current.account.logo.destroy`: the attachment row goes (its `touch: true` moves the account's updated_at, so the
  # logo's `?v=`), then ActiveStorage::PurgeJob purges the blob: its variant records, their image attachments and blobs,
  # and the blob row. The files stay on disk (the job's deletes are not reproduced; nothing serves a purged key).
  execute :touch_account_for_logo, args: {} do
    where(expr(:logo_attached)).touch
  end

  # Account#logo.destroy as one step, for the logo whose blob id is given: the statements above and the blob's own
  # deletes, in one transaction.
  def purge_account_logo(logo)
    variants = variant_blob_ids(blob_id: logo)
    transaction do
      touch_account_for_logo
      detach_variant_images(blob_id: logo)
      delete_variant_records(blob_id: logo)
      delete_blobs(ids: variants)
      detach_account_logo
      delete_blob(id: logo)
    end
  end

  # The account's logo blob, the source of Account#logo_variant(size): `logo.variant(size).processed if logo.variable?`,
  # made on the first request for that size (models/variant.axum.rb).
  record :LogoSource do
    field :key, :string
    field :filename, :string
    field :content_type, :string, optional: true
  end

  # FirstRunsController: the set-up form an empty install shows, and the account, administrator and first room it

  # creates. `prevent_repeats` sends both actions to / once an account exists (Account.any?).
  query :account_count, args: {}, returns: :i64 do
    count
  end
end
