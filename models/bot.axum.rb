model do
  # User.create_bot!: a random 12-letter alphanumeric bot_token (SecureRandom.alphanumeric) and role 2 (bot); no
  # address or password (has_secure_password validations: false).
  query :create_bot_user, args: { name: :string }, returns: :i64, sql: <<~SQL
    WITH RECURSIVE pick(n, code) AS (
      SELECT 0, ''
      UNION ALL
      SELECT n + 1, code || substr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789', (abs(random()) % 62) + 1, 1)
      FROM pick WHERE n < 12
    )
    INSERT INTO users (name, bot_token, role, status, created_at, updated_at)
    SELECT :name, code, 2, 0, strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now') FROM pick WHERE n = 12
    RETURNING id
  SQL

  # User.create_bot!(name:, avatar:, webhook_url:): the bot user, its webhook whenever the form sent the field (an empty
  # URL included: `if webhook_url`) and its avatar in one transaction, then the user's after_create_commit grant to
  # every open room.
  def create_bot(name, webhook, avatar)
    has_webhook = !webhook.nil?
    webhook_url = webhook || ""
    stored = avatar&.store_file(setting(:storage))
    bot_id = transaction do
      id = create_bot_user(name: name)
      if has_webhook
        create_webhook(user_id: id, url: webhook_url)
      end
      attach(:avatar, id, stored, fresh: true)
      id
    end
    grant_open_rooms_to(user_id: bot_id)
  end

  # User#update_bot!: the webhook updated or created when the URL is present and destroyed when blank, then
  # update!(name:, avatar:) (a new avatar replaces the old attachment; Rails purges the old blob in a later job). The
  # rows the rename changed: 1, or 0 when the bot is gone.
  def update_bot(id, name, webhook, avatar)
    webhook_url = webhook || ""
    present = webhook_url.strip != "" # `url.present?`; the URL is stored as sent
    had = webhook_count(user_id: id) > 0
    stored = avatar&.store_file(setting(:storage))
    transaction do
      if present
        update_webhook(user_id: id, url: webhook_url)
      end
      if present && !had
        create_webhook(user_id: id, url: webhook_url)
      end
      if !present
        delete_webhook(user_id: id)
      end
      attach(:avatar, id, stored)
      rename_bot(id: id, name: name)
    end
  end

  # User#reset_bot_key: `update! bot_token: generate_bot_token`.
  execute :reset_bot_token, args: { id: :i64 }, sql: <<~SQL
    WITH RECURSIVE pick(n, code) AS (
      SELECT 0, ''
      UNION ALL
      SELECT n + 1, code || substr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789', (abs(random()) % 62) + 1, 1)
      FROM pick WHERE n < 12
    )
    UPDATE users SET bot_token = (SELECT code FROM pick WHERE n = 12), updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now')
    WHERE id = :id
  SQL

  # The query string's bot_key value, up to the next `&` (a key is "<id>-<token>", URL-safe).
  helper :bot_key_param, args: [:string], returns: :string? do |query|
    parts = "&#{query}".partition("&bot_key=")
    return nil if (parts[1] || "") != "&bot_key="
    (parts[2] || "").partition("&")[0] || ""
  end
end
