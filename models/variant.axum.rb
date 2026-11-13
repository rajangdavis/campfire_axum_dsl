model do
  # --- Active Storage variants (ActiveStorage::VariantWithRecord) ---------------------------------------------------
  # `blob.variant(name).processed`: when the blob has no variant record under the variation's digest, the image is
  # resized with libvips (image_variant, ImageProcessing::Vips's resize_to_limit) and Active Storage writes the record
  # (`variant_records.create_or_find_by!(variation_digest:)`), the variant blob (named "<filename base>.<format>",
  # analyzed) and the record's `image` attachment. The digests are `Variation#digest`, SHA1 of Marshal.dump of the
  # transformations, read from Rails (2026-11-06):
  #   Account :large  resize_to_limit [512, 512], png     ksXvpLsa7BuCVyHOwmQOKedbIbM=
  #   Account :small  resize_to_limit [192, 192], png     EXATZfM7OVVC86CDh85TOsa8ZSw=
  #   User :square    resize_to_limit [512, 512], webp    6gwfjNKv9eUy9jNUtEZvQFLU0hQ=
  #   Message :thumb  resize_to_limit [1200, 800], the blob's default variant format: png aFrmZ9PxOH5XKtnRmopvClCmS1g=,
  #                   jpg IBhrLAIapu+NCId+2Kz6EqUWRKY=, gif QhvxvYWo0o2axWU0l3EW8VQDYbM=, webp u0TSbUypNLiezYYkiqbZ8jAyVv0=,
  #                   and png for the other variable types (tiff, avif, heic, heif) E5GdheK2KKwpmZTUH1L2aXvHokU=
  #                   (`default_to(format: :png)`, a symbol, where a web image's format is a string).

  # ActiveStorage.variable_content_types, what `variable?` (and `representable?` for an image) asks for.
  helper :variable_content_type, args: [:string], returns: :bool do |content_type|
    ["image/png", "image/gif", "image/jpeg", "image/tiff", "image/webp", "image/avif", "image/heic", "image/heif"].include?(content_type)
  end

  # The :thumb variant's format and digest for a blob's content type (Blob#default_variant_format).
  record :ThumbVariation do
    field :format, :string
    field :digest, :string
  end

  query :thumb_variation, args: { content_type: :string }, returns: :ThumbVariation?, sql: <<~SQL
    SELECT CASE :content_type WHEN 'image/png' THEN 'png' WHEN 'image/jpeg' THEN 'jpg' WHEN 'image/gif' THEN 'gif'
                              WHEN 'image/webp' THEN 'webp' ELSE 'png' END AS format,
           CASE :content_type WHEN 'image/png' THEN 'aFrmZ9PxOH5XKtnRmopvClCmS1g=' WHEN 'image/jpeg' THEN 'IBhrLAIapu+NCId+2Kz6EqUWRKY='
                              WHEN 'image/gif' THEN 'QhvxvYWo0o2axWU0l3EW8VQDYbM=' WHEN 'image/webp' THEN 'u0TSbUypNLiezYYkiqbZ8jAyVv0='
                              ELSE 'E5GdheK2KKwpmZTUH1L2aXvHokU=' END AS digest
  SQL

  # VariantWithRecord#filename: "#{blob.filename.base}.#{format}". ActiveStorage::Filename#base is Ruby's
  # File.basename(name, File.extname(name)): everything before the last dot, unless the only dots lead the name.
  helper :variant_filename, args: [:string, :string], returns: :string do |filename, format|
    # Split at the last dot (the first one of the reversed name): parts[2] is what precedes it, reversed back.
    parts = filename.reverse.partition(".")
    base = (parts[2] || "").reverse
    # No dot, or only dots before the last one (".bashrc", "..a"): the whole name is the base.
    "#{base.delete(".") == "" ? filename : base}.#{format}"
  end

  # The variant blob's key, when the blob already has the variant (the record and its image).
  query :processed_variant_key, args: { blob_key: :string, digest: :string }, returns: :string?, sql: <<~SQL
    SELECT variant_blobs.key
    FROM active_storage_blobs AS sources
    JOIN active_storage_variant_records AS variants ON variants.blob_id = sources.id AND variants.variation_digest = :digest
    JOIN active_storage_attachments AS images
      ON images.record_type = 'ActiveStorage::VariantRecord' AND images.record_id = variants.id AND images.name = 'image'
    JOIN active_storage_blobs AS variant_blobs ON variant_blobs.id = images.blob_id
    WHERE sources.key = :blob_key
    ORDER BY variants.id DESC LIMIT 1
  SQL

  # create_or_find_by!(variation_digest:) and `record.image.attach(io)`: the record (create_variant_record, in
  # models/variant_record.axum.rb), then (insert_blob, models/blob.axum.rb) the variant blob, then the attachment that ties them.

  execute :attach_variant_image, args: { blob_key: :string, digest: :string, variant_key: :string }, sql: <<~SQL
    INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at)
    SELECT 'image', 'ActiveStorage::VariantRecord', variants.id, variant_blobs.id, strftime('%Y-%m-%d %H:%M:%f', 'now')
    FROM active_storage_blobs AS sources
    JOIN active_storage_variant_records AS variants ON variants.blob_id = sources.id AND variants.variation_digest = :digest
    JOIN active_storage_blobs AS variant_blobs ON variant_blobs.key = :variant_key
    WHERE sources.key = :blob_key
    ORDER BY variants.id DESC LIMIT 1
  SQL

  # `blob.variant(...).processed` for a variable blob (resize_to_limit [limit, limit] in the given format): the
  # variant blob's key, made and recorded on the first request that asks for it. "" when the blob is not variable
  # (or there is none: an empty key), or when the image could not be processed.
  def processed_variant(source_key, source_type, filename, digest, format, limit)
    variable = source_key != "" && variable_content_type(source_type)
    storage = setting(:storage)
    existing = variable ? processed_variant_key(blob_key: source_key, digest: digest) : nil
    if variable && existing.nil?
      variant = image_variant("#{storage}/#{source_key[0, 2].to_s}/#{source_key[2, 2].to_s}/#{source_key}", variant_filename(filename, format), limit, limit)
      variant_name = variant&.filename || ""
      variant_type = variant&.content_type || ""
      variant_metadata = variant&.metadata || ""
      variant_size = variant&.size || 0
      variant_checksum = variant&.checksum || ""
      variant_key = if variant.nil?
        ""
      else
        variant.store(storage)
      end
      if variant_key != ""
        transaction do
          create_variant_record(blob_key: source_key, digest: digest)
          insert_blob(key: variant_key, filename: variant_name, content_type: variant_type, metadata: variant_metadata, byte_size: variant_size, checksum: variant_checksum)
          attach_variant_image(blob_key: source_key, digest: digest, variant_key: variant_key)
        end
      end
    end
    variable ? (processed_variant_key(blob_key: source_key, digest: digest) || "") : ""
  end
end
