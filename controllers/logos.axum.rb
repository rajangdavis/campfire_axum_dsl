controller do
  # Accounts::LogosController#show (allow_unauthenticated_access): the account logo's processed :large (512) or :small
  # (192, `?size=small`) PNG variant from Active Storage's Disk service, made on the first request for it, public for five minutes with a one-week
  # stale-while-revalidate. `?v=` only busts caches. An account without a logo answers the stock app-icon PNGs from
  # public/logos (relative to the working directory, as the app runs).
  params :LogoParams do
    field :size, :string, in: :query, optional: true
  end

  def show
    small = params[:size].to_s == "small" ? 1 : 0
    # :small is resize_to_limit [192, 192], :large [512, 512], both png.
    digest = small == 1 ? "EXATZfM7OVVC86CDh85TOsa8ZSw=" : "ksXvpLsa7BuCVyHOwmQOKedbIbM="
    limit = small == 1 ? 192 : 512
    source = logo_source
    storage = setting(:storage)
    logo_key = processed_variant(source&.key || "", source&.content_type || "", source&.filename || "", digest, "png", limit)
    # stale?(etag: Current.account): the tag follows the account's updated_at, for the logo and the stock icon alike;
    # before the first run there is no account, and `etag: nil` writes no ETag (an empty etag writes none).
    version = account_logo_version
    etag(version.nil? ? "" : "W/\"account-#{version}\"")
    headers "Cache-Control" => "public, max-age=300, stale-while-revalidate=604800",
            # Accounts::LogosController includes ActiveStorage::Streaming (ActionController::Live): no default headers.
            "X-Rack-Defaults" => "live"
    # One answer at the end, not an early `return`: a return leaves before the headers and the ETag above are put on.
    # send_stock_icon: app/assets/images/logos/app-icon{,-192}.png, kept in public/logos.
    stock = small == 1 ? file_path(:stock_logo_small_file) : file_path(:stock_logo_file)
    path = logo_key.empty? ? stock : "#{storage}/#{logo_key[0, 2].to_s}/#{logo_key[2, 2].to_s}/#{logo_key}"
    send_file(path, content_type: "image/png", disposition: :inline)
  end
end
