fragment do
  # Active Storage's own controllers (activestorage/config/routes.rb), which inherit ActiveStorage::BaseController: no
  # session filters, no allow_browser, no X-Version/X-Rev (the "engine" marker), but Rails' default security headers.
  # A blob is public behind its signed id, and the disk URL behind its signed, expiring key.

  params :RepresentationPath do
    field :signed_blob_id, :string, in: :path
    field :variation_key, :string, in: :path
    field :filename, :string, in: :path
  end

  params :BlobPath do
    field :signed_blob_id, :string, in: :path
    field :filename, :string, in: :path
  end

  params :DiskPath do
    field :encoded_key, :string, in: :path
    field :filename, :string, in: :path
  end

  record :Representation do
    field :key, :string
    field :filename, :string
    field :content_type, :string
  end

  # `blob.representation(variation).processed`, read from the seed's records: the variant record's image blob, or for
  # a previewable blob (a video) the variant of its preview image. A blob has one variant record in the seed, so the
  # variation key is not matched to a variation digest (Marshal.dump + SHA1); the newest variant record answers. A blob
  # uploaded since the seed has none (the DSL cannot process an image): it takes the variant of a message attachment
  # with the same checksum, which vips would have made from the same bytes; the blob's own variant comes first.
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

  # The blob a disk key names; Last-Modified is the file's, approximated by the blob's creation time as an HTTP date.
  query :disk_blob, args: { key: :string }, returns: :DiskBlob?, sql: <<~SQL
    SELECT content_type, filename,
           CASE strftime('%w', created_at) WHEN '0' THEN 'Sun' WHEN '1' THEN 'Mon' WHEN '2' THEN 'Tue' WHEN '3' THEN 'Wed'
                WHEN '4' THEN 'Thu' WHEN '5' THEN 'Fri' ELSE 'Sat' END
           || strftime(', %d ', created_at)
           || CASE strftime('%m', created_at) WHEN '01' THEN 'Jan' WHEN '02' THEN 'Feb' WHEN '03' THEN 'Mar' WHEN '04' THEN 'Apr'
                WHEN '05' THEN 'May' WHEN '06' THEN 'Jun' WHEN '07' THEN 'Jul' WHEN '08' THEN 'Aug' WHEN '09' THEN 'Sep'
                WHEN '10' THEN 'Oct' WHEN '11' THEN 'Nov' ELSE 'Dec' END
           || strftime(' %Y %H:%M:%S GMT', created_at) AS last_modified
    FROM active_storage_blobs WHERE key = :key
  SQL

  record :BlobFile do
    field :key, :string
    field :filename, :string
    field :content_type, :string
  end

  query :blob_file, args: { id: :i64 }, returns: :BlobFile?, sql: <<~SQL
    SELECT key, filename, content_type FROM active_storage_blobs WHERE id = :id
  SQL

  # Blobs::RedirectController#show: `expires_in ActiveStorage.service_urls_expire_in` (five minutes, private), then
  # `redirect_to @blob.url(disposition:), allow_other_host: true`: the original blob, no variant. As for the
  # representation redirect, the answer carries the session cookie (the "write_session" marker). A bad signature is
  # `head :not_found`.
  get "/rails/active_storage/blobs/redirect/:signed_blob_id/:filename", params: :BlobPath,
      description: "A blob's original file: a redirect to its disk service URL", skip: [:authenticate, :allow_browser] do
    blob_id = active_storage_verified_id(params[:signed_blob_id], secret: :secret_key)
    return halt(404, "") if blob_id.nil?
    blob = blob_file(id: blob_id)
    return halt(404, "") if blob.nil?
    path = active_storage_disk_path(blob.key, blob.filename, blob.content_type, secret: :secret_key)
    headers "Location" => "#{request_base_url}#{path}", "Cache-Control" => "max-age=300, private",
            "Content-Type" => "text/html; charset=utf-8", "X-Rack-Defaults" => "engine, write_session"
    halt(302, "")
  end

  # Representations::RedirectController#show: `expires_in ActiveStorage.service_urls_expire_in` (five minutes, private),
  # then `redirect_to image.url(disposition:), allow_other_host: true`: an absolute URL to the disk service. A bad
  # signature is `head :not_found`.
  get "/rails/active_storage/representations/redirect/:signed_blob_id/:variation_key/:filename", params: :RepresentationPath,
      description: "A blob's processed variant: a redirect to its disk service URL", skip: [:authenticate, :allow_browser] do
    blob_id = active_storage_verified_id(params[:signed_blob_id], secret: :secret_key)
    return halt(404, "") if blob_id.nil?
    # A blob with no variant record (one uploaded since the seed) answers its original file: the DSL cannot process a
    # variant yet (Rails would resize_to_limit [1200, 800]), and a 404 here leaves a 0x0 broken <img> the page never shows.
    record_poster_marker(id: blob_id)
    record_poster_blob(id: blob_id)
    record_poster_attachment(id: blob_id)
    image = blob_representation(id: blob_id)
    blob = blob_file(id: blob_id)
    return halt(404, "") if blob.nil?
    path = active_storage_disk_path(image&.key || blob.key, image&.filename || blob.filename, image&.content_type || blob.content_type, secret: :secret_key)
    headers "Location" => "#{request_base_url}#{path}", "Cache-Control" => "max-age=300, private",
            "Content-Type" => "text/html; charset=utf-8", "X-Rack-Defaults" => "engine, write_session"
    halt(302, "")
  end

  # DiskController#show, plus the initializer's `after_action` cache header (`max-age=3600, public`): the blob's file,
  # inline, named by the signed disposition. The key must verify and not have expired.
  get "/rails/active_storage/disk/:encoded_key/:filename", params: :DiskPath,
      description: "A blob's file from the disk service", skip: [:authenticate, :allow_browser] do
    key = active_storage_verified_key(params[:encoded_key], secret: :secret_key)
    return halt(404, "") if key.nil?
    blob = disk_blob(key: key)
    return halt(404, "") if blob.nil?
    storage = setting(:storage)
    path = "#{storage}/#{key[0, 2].to_s}/#{key[2, 2].to_s}/#{key}"
    headers "Content-Type" => blob.content_type, "Content-Disposition" => inline_disposition(blob.filename),
            "Cache-Control" => "max-age=3600, public", "Last-Modified" => blob.last_modified, "X-Rack-Defaults" => "engine"
    send_file(path, content_type: "application/octet-stream")
  end
end
