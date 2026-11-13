# The tables of db/migrate/001_schema.sql and 002_sidebar_direct_cache.sql that the statements touch, column for column
# in the migration's order. A datetime, text, varchar or json column is a :string, an integer or bigint an :i64; a column
# without NOT NULL is optional. The models (models/*.axum.rb) own these tables; nothing here emits Rust.
fragment do
  table :accounts do
    field :id, :i64
    field :created_at, :string
    field :custom_styles, :string, optional: true
    field :join_code, :string
    field :name, :string
    field :settings, :string, optional: true
    field :singleton_guard, :i64
    field :updated_at, :string
  end

  table :action_text_rich_texts do
    field :id, :i64
    field :body, :string, optional: true
    field :created_at, :string
    field :name, :string
    field :record_id, :i64
    field :record_type, :string
    field :updated_at, :string
  end

  table :active_storage_blobs do
    field :id, :i64
    field :byte_size, :i64
    field :checksum, :string, optional: true
    field :content_type, :string, optional: true
    field :created_at, :string
    field :filename, :string
    field :key, :string
    field :metadata, :string, optional: true
    field :service_name, :string
  end

  table :active_storage_attachments do
    field :id, :i64
    field :blob_id, :i64
    field :created_at, :string
    field :name, :string
    field :record_id, :i64
    field :record_type, :string
  end

  table :active_storage_variant_records do
    field :id, :i64
    field :blob_id, :i64
    field :variation_digest, :string
  end

  table :users do
    field :id, :i64
    field :bio, :string, optional: true
    field :bot_token, :string, optional: true
    field :created_at, :string
    field :email_address, :string, optional: true
    field :name, :string
    field :password_digest, :string, optional: true
    field :role, :i64
    field :status, :i64
    field :updated_at, :string
  end

  table :bans do
    field :id, :i64
    field :created_at, :string
    field :ip_address, :string
    field :updated_at, :string
    field :user_id, :i64
  end

  table :rooms do
    field :id, :i64
    field :created_at, :string
    field :creator_id, :i64
    field :name, :string, optional: true
    field :type, :string
    field :updated_at, :string
  end

  table :memberships do
    field :id, :i64
    field :connected_at, :string, optional: true
    field :connections, :i64
    field :created_at, :string
    field :involvement, :string, optional: true
    field :room_id, :i64
    field :unread_at, :string, optional: true
    field :updated_at, :string
    field :user_id, :i64
  end

  table :messages do
    field :id, :i64
    field :client_message_id, :string
    field :created_at, :string
    field :creator_id, :i64
    field :room_id, :i64
    field :updated_at, :string
  end

  table :boosts do
    field :id, :i64
    field :booster_id, :i64
    field :content, :string
    field :created_at, :string
    field :message_id, :i64
    field :updated_at, :string
  end

  table :push_subscriptions do
    field :id, :i64
    field :auth_key, :string, optional: true
    field :created_at, :string
    field :endpoint, :string, optional: true
    field :p256dh_key, :string, optional: true
    field :updated_at, :string
    field :user_agent, :string, optional: true
    field :user_id, :i64
  end

  table :searches do
    field :id, :i64
    field :created_at, :string
    field :query, :string
    field :updated_at, :string
    field :user_id, :i64
  end

  table :sessions do
    field :id, :i64
    field :created_at, :string
    field :ip_address, :string, optional: true
    field :last_active_at, :string
    field :token, :string
    field :updated_at, :string
    field :user_agent, :string, optional: true
    field :user_id, :i64
  end

  table :webhooks do
    field :id, :i64
    field :created_at, :string
    field :updated_at, :string
    field :url, :string, optional: true
    field :user_id, :i64
  end

  # The FTS5 index (tokenize=porter): rowid is the message's id.
  table :message_search_index do
    field :rowid, :i64
    field :body, :string
  end

  # 002_sidebar_direct_cache.sql: the stand-in for Rails' fragment cache (models/sidebar.axum.rb); its key is the pair.
  table :axum_dsl_sidebar_direct_cache do
    field :membership_id, :i64
    field :membership_updated_at, :string
    field :unread, :i64
  end
end
