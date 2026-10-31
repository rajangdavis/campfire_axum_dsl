fragment do
  # --- avatars (app/controllers/users/avatars_controller.rb, app/models/user/avatar.rb) ---------------------------

  # The processed :square variant's blob key. Rails' avatar_variant is `avatar.variant(:square).processed`; the
  # variant record's `image` attachment is the processed blob, and the source blob is the user's avatar. The DSL
  # cannot process an image, so a newly uploaded avatar takes the :square variant of another avatar blob with the
  # same checksum (the same bytes, which vips turns into the same variant); the user's own variant comes first.
  record :Avatar do
    field :key, :string
  end

  query :avatar_variant, args: { user_id: :i64 }, returns: :Avatar?, sql: <<~SQL
    SELECT variant_blobs.key AS key
    FROM active_storage_attachments AS avatars
    JOIN active_storage_blobs AS sources ON sources.id = avatars.blob_id
    JOIN active_storage_blobs AS twins ON twins.id = sources.id OR twins.checksum = sources.checksum
    JOIN active_storage_attachments AS twin_avatars
      ON twin_avatars.blob_id = twins.id AND twin_avatars.record_type = 'User' AND twin_avatars.name = 'avatar'
    JOIN active_storage_variant_records AS variants ON variants.blob_id = twins.id
    JOIN active_storage_attachments AS images
      ON images.record_type = 'ActiveStorage::VariantRecord'
     AND images.record_id = variants.id
     AND images.name = 'image'
    JOIN active_storage_blobs AS variant_blobs ON variant_blobs.id = images.blob_id
    WHERE avatars.record_type = 'User' AND avatars.record_id = :user_id AND avatars.name = 'avatar'
    ORDER BY twins.id = sources.id DESC, variants.id DESC LIMIT 1
  SQL

  # Users::AvatarsController#show when the variant is absent: User#name, User#initials and User#bot? (role 2),
  # plus the cache-key version `stale?(etag: @user)` derives. initials is `name.scan(/\b\w/).join`: the
  # recursive CTE walks the name's characters and keeps each word's first ASCII word character in order.
  # Ruby's `\w` is ASCII-only, so a leading Unicode letter is not reproduced; the seed names are ASCII.
  record :AvatarFallback do
    field :name, :string
    field :initials, :string
    field :bot, :bool
    field :version, :string
  end

  query :avatar_fallback, args: { user_id: :i64 }, returns: :AvatarFallback?, sql: <<~SQL
    WITH RECURSIVE
    user_row(id, name, role, updated_at) AS (
      SELECT id, name, role, updated_at FROM users WHERE id = :user_id
    ),
    positions(i) AS (
      SELECT 1
      UNION ALL
      SELECT i + 1 FROM positions WHERE i < (SELECT length(name) FROM user_row)
    ),
    initials AS (
      SELECT group_concat(ch, '') AS value FROM (
        SELECT substr(u.name, p.i, 1) AS ch
        FROM user_row u JOIN positions p ON p.i <= length(u.name)
        WHERE instr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_', substr(u.name, p.i, 1)) > 0
          AND (p.i = 1 OR instr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_', substr(u.name, p.i - 1, 1)) = 0)
        ORDER BY p.i
      )
    )
    SELECT u.name AS name, COALESCE(i.value, '') AS initials,
           CASE WHEN u.role = 2 THEN 1 ELSE 0 END AS bot,
           strftime('%Y%m%d%H%M%S', u.updated_at) AS version
    FROM user_row u, initials i
  SQL
  # --- uploads (docs/dsl.md, "Uploads") -----------------------------------------------------------------------------
  # ActiveStorage::Blob.create_and_upload!: the row of a file `upload.store(root)` has written, found again by its key. A
  # route with no file passes the key "", and the statements here run on every request and do nothing for it (a
  # transaction holds statements only, and the DSL has no statement-level `if`). The caller passes the metadata: a
  # message attachment the upload's analyzed `metadata` (Rails renders the new message with its width and height), an
  # avatar `{"identified":true}` (analysis is a later job there).
  execute :insert_blob, args: { key: :string, filename: :string, content_type: :string, metadata: :string, byte_size: :i64, checksum: :string }, sql: <<~SQL
    INSERT INTO active_storage_blobs (key, filename, content_type, metadata, service_name, byte_size, checksum, created_at)
    SELECT :key, :filename, :content_type, :metadata, 'local', :byte_size, :checksum, strftime('%Y-%m-%d %H:%M:%f', 'now')
    WHERE :key <> ''
  SQL

  # has_one_attached :avatar on a User: one attachment, so a new blob replaces the old one (Rails purges the old blob
  # later, a job this service does not run), and the attachment touches the user (belongs_to :record, touch: true),
  # which moves the avatar URL's `?v=`. The three do nothing for the key "".
  execute :detach_user_avatar, args: { user_id: :i64, key: :string }, sql: <<~SQL
    DELETE FROM active_storage_attachments WHERE record_type = 'User' AND record_id = :user_id AND name = 'avatar'
      AND :key <> '' AND EXISTS (SELECT 1 FROM active_storage_blobs WHERE key = :key)
  SQL

  execute :attach_user_avatar, args: { user_id: :i64, key: :string }, sql: <<~SQL
    INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at)
    SELECT 'avatar', 'User', :user_id, b.id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM active_storage_blobs b WHERE b.key = :key AND :key <> ''
  SQL

  execute :touch_user_for_avatar, args: { user_id: :i64, key: :string }, sql: <<~SQL
    UPDATE users SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now')
    WHERE id = :user_id AND :key <> '' AND EXISTS (SELECT 1 FROM active_storage_blobs WHERE key = :key)
  SQL
end
