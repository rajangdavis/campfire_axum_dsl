model do
  record :Representation do
    field :key, :string
    field :filename, :string
    field :content_type, :string
  end

  # `blob.representation(variation).processed`, read from the seed's records: the variant record's image blob, or for
  # a previewable blob (a video) the variant of its preview image. A blob has one variant record in the seed, so the
  # variation key is not matched to a variation digest (Marshal.dump + SHA1); the newest variant record answers. An image
  # uploaded since the seed has its :thumb from the post that attached it (Message#process_attachment, image_variant); a
  # blob still without one takes the variant of a message attachment with the same checksum (the same bytes, the same
  # variant); the blob's own variant comes first.
  query :blob_representation, args: { id: :i64 }, returns: :Representation?, sql: <<~SQL
    SELECT variant_blobs.key AS key, variant_blobs.filename AS filename, variant_blobs.content_type AS content_type
    FROM (
      SELECT COALESCE(
        (SELECT previews.blob_id FROM active_storage_attachments AS previews
          WHERE previews.record_type = 'ActiveStorage::Blob' AND previews.record_id = :id AND previews.name = 'preview_image'
          LIMIT 1),
        :id) AS blob_id
    ) AS source
    JOIN active_storage_blobs AS sources ON sources.id = source.blob_id
    JOIN active_storage_blobs AS twins ON twins.id = sources.id
      OR (twins.checksum = sources.checksum AND EXISTS (SELECT 1 FROM active_storage_attachments AS uses
          WHERE uses.blob_id = twins.id AND uses.record_type = 'Message' AND uses.name = 'attachment'))
    JOIN active_storage_variant_records AS variants ON variants.blob_id = twins.id AND variants.variation_digest <> 'axum_dsl:poster'
    JOIN active_storage_attachments AS images
      ON images.record_type = 'ActiveStorage::VariantRecord'
     AND images.record_id = variants.id
     AND images.name = 'image'
    JOIN active_storage_blobs AS variant_blobs ON variant_blobs.id = images.blob_id
    ORDER BY twins.id = sources.id DESC, variants.id DESC LIMIT 1
  SQL

  # The page's poster request for a video makes Rails process the preview's variant again: the seed's poster variant
  # (once-campfire-rust/parity/seeds/lib/seed.rb process_poster) is not under the digest the page asks for, so the first
  # request in a fresh database writes a variant record, its blob and the `image` attachment (owner's probe on the VM,
  # 2026-10-29: variant 7 of blob 10, blob 15 alpha-centuri.webp), and the next upload's blob id is one higher. The
  # three rows below are that side effect, once per preview; the poster served stays the seed's (the same bytes).
  execute :record_poster_marker, args: { id: :i64 }, sql: <<~SQL
    INSERT INTO active_storage_variant_records (blob_id, variation_digest)
    SELECT previews.blob_id, 'axum_dsl:poster' FROM active_storage_attachments AS previews
    WHERE previews.record_type = 'ActiveStorage::Blob' AND previews.record_id = :id AND previews.name = 'preview_image'
      AND NOT EXISTS (SELECT 1 FROM active_storage_variant_records AS done
                      WHERE done.blob_id = previews.blob_id AND done.variation_digest = 'axum_dsl:poster')
  SQL

  execute :record_poster_blob, args: { id: :i64 }, sql: <<~SQL
    INSERT INTO active_storage_blobs (key, filename, content_type, metadata, service_name, byte_size, checksum, created_at)
    SELECT 'axumdslposter' || marker.id, poster.filename, poster.content_type, poster.metadata, poster.service_name,
           poster.byte_size, poster.checksum, strftime('%Y-%m-%d %H:%M:%f', 'now')
    FROM active_storage_attachments AS previews
    JOIN active_storage_variant_records AS marker ON marker.blob_id = previews.blob_id AND marker.variation_digest = 'axum_dsl:poster'
    JOIN active_storage_variant_records AS seeded ON seeded.blob_id = previews.blob_id AND seeded.variation_digest <> 'axum_dsl:poster'
    JOIN active_storage_attachments AS images ON images.record_type = 'ActiveStorage::VariantRecord' AND images.record_id = seeded.id AND images.name = 'image'
    JOIN active_storage_blobs AS poster ON poster.id = images.blob_id
    WHERE previews.record_type = 'ActiveStorage::Blob' AND previews.record_id = :id AND previews.name = 'preview_image'
      AND NOT EXISTS (SELECT 1 FROM active_storage_blobs AS made WHERE made.key = 'axumdslposter' || marker.id)
    ORDER BY seeded.id DESC LIMIT 1
  SQL

  execute :record_poster_attachment, args: { id: :i64 }, sql: <<~SQL
    INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at)
    SELECT 'image', 'ActiveStorage::VariantRecord', marker.id, made.id, strftime('%Y-%m-%d %H:%M:%f', 'now')
    FROM active_storage_attachments AS previews
    JOIN active_storage_variant_records AS marker ON marker.blob_id = previews.blob_id AND marker.variation_digest = 'axum_dsl:poster'
    JOIN active_storage_blobs AS made ON made.key = 'axumdslposter' || marker.id
    WHERE previews.record_type = 'ActiveStorage::Blob' AND previews.record_id = :id AND previews.name = 'preview_image'
      AND NOT EXISTS (SELECT 1 FROM active_storage_attachments AS linked
                      WHERE linked.record_type = 'ActiveStorage::VariantRecord' AND linked.record_id = marker.id)
  SQL

  record :DiskBlob do
    field :content_type, :string
    field :filename, :string
    field :last_modified, :string
  end

  record :BlobFile do
    field :key, :string
    field :filename, :string
    field :content_type, :string, optional: true
  end

  record :DirectUploadRow do

    field :id, :i64
    field :created_at, :string
  end

  query :create_direct_upload_blob, args: { key: :string, filename: :string, content_type: :string, byte_size: :i64, checksum: :string },
        returns: :DirectUploadRow?, sql: <<~SQL
    INSERT INTO active_storage_blobs (key, filename, content_type, metadata, service_name, byte_size, checksum, created_at)
    VALUES (:key, :filename, NULLIF(:content_type, ''), '{}', 'local', :byte_size, :checksum, strftime('%Y-%m-%d %H:%M:%f', 'now'))
    RETURNING id, strftime('%Y-%m-%dT%H:%M:%fZ', created_at) AS created_at
  SQL
end
