fragment do
  # Accounts::LogosController#show (allow_unauthenticated_access): the account logo's processed :large (512) or :small
  # (192, `?size=small`) PNG variant from Active Storage's Disk service, public for five minutes with a one-week
  # stale-while-revalidate. `?v=` only busts caches. An account without a logo answers the stock app-icon PNGs from
  # public/logos (relative to the working directory, as the app runs).
  params :LogoParams do
    field :size, :string, in: :query, optional: true
  end

  record :LogoBlob do
    field :key, :string
  end

  # The variant blobs of the account's logo; the small one is the smaller file.
  query :logo_variant, args: { small: :i64 }, returns: :LogoBlob?, sql: <<~SQL
    SELECT variant_blobs.key AS key
    FROM active_storage_attachments AS logos
    JOIN active_storage_variant_records AS variants ON variants.blob_id = logos.blob_id
    JOIN active_storage_attachments AS images
      ON images.record_type = 'ActiveStorage::VariantRecord'
     AND images.record_id = variants.id
     AND images.name = 'image'
    JOIN active_storage_blobs AS variant_blobs ON variant_blobs.id = images.blob_id
    WHERE logos.record_type = 'Account' AND logos.name = 'logo'
    ORDER BY CASE WHEN :small = 1 THEN variant_blobs.byte_size END ASC, variant_blobs.byte_size DESC LIMIT 1
  SQL

  get "/account/logo", params: :LogoParams, description: "The account logo (PNG variant)", skip: [:authenticate] do
    small = params[:size].to_s == "small" ? 1 : 0
    logo = logo_variant(small: small)
    # stale?(etag: Current.account): the tag follows the account's updated_at, for the logo and the stock icon alike.
    etag("W/\"account-#{account_logo_version || ""}\"")
    headers "Cache-Control" => "public, max-age=300, stale-while-revalidate=604800",
            # Accounts::LogosController includes ActiveStorage::Streaming (ActionController::Live): no default headers.
            "X-Rack-Defaults" => "live"
    # One answer at the end, not an early `return`: a return leaves before the headers and the ETag above are put on.
    # send_stock_icon: app/assets/images/logos/app-icon{,-192}.png, kept in public/logos.
    stock = small == 1 ? file_path(:stock_logo_small_file) : file_path(:stock_logo_file)
    key = logo.nil? ? "" : logo.key
    storage = setting(:storage)
    path = key.empty? ? stock : "#{storage}/#{key[0, 2].to_s}/#{key[2, 2].to_s}/#{key}"
    send_file(path, content_type: "image/png", disposition: :inline)
  end
end
