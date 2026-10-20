fragment do
  # Users::AvatarsController#show: a signed_id token names the user, the stored :square variant is served from
  # Active Storage's local Disk service. Rails serves image/webp, inline, with a 30-minute public cache and a
  # one-week stale-while-revalidate; the variant is already processed, so this route never resizes.
  get "/users/:token/avatar", params: :AvatarPath, description: "A user's processed avatar (Rails signed_id token)" do
    user_id = rails_signed_id(params[:token], purpose: "user/avatar", secret: :secret_key)
    return halt(404, "") if user_id.nil?
    avatar = avatar_variant(user_id: user_id)
    return halt(404, "") if avatar.nil?
    key = avatar.key
    storage = setting(:storage)
    first = key[0, 2].to_s
    second = key[2, 2].to_s
    path = "#{storage}/#{first}/#{second}/#{key}"
    # Rails' stale?(etag: @user) is a weak validator over the user's cache key; the variant key is the byte
    # identity this service has, and changes when the processed avatar does.
    etag("W/\"avatar-#{key}\"")
    headers "Cache-Control" => "public, max-age=1800, stale-while-revalidate=604800",
            "Content-Disposition" => "inline"
    send_file(path, content_type: "image/webp")
  end
end
