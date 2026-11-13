controller do
  # Users::AvatarsController#show: a signed_id token names the user. The stored :square variant is served from
  # Active Storage's local Disk service; without one Rails serves the default-bot SVG for a bot and the
  # initials SVG otherwise. The send_file responses are inline (Rails' send_file headers), the initials SVG carries
  # no Content-Disposition; every response has a 30-minute public cache and a one-week
  # stale-while-revalidate, and the weak ETag is Rails' stale?(etag: @user).
  def show
    user_id = rails_signed_id(params[:token], purpose: "user/avatar", secret: :secret_key)
    return halt(404, "") if user_id.nil?
    fallback = avatar_fallback(user_id: user_id)
    return halt(404, "") if fallback.nil?
    # User#avatar_variant: the :square variant (resize_to_limit [512, 512], webp) of a variable avatar, processed on the
    # first request that asks for it (models/variant.axum.rb).
    source = avatar_source(user_id: user_id)
    storage = setting(:storage)
    avatar_key = processed_variant(source&.key || "", source&.content_type || "", source&.filename || "", "6gwfjNKv9eUy9jNUtEZvQFLU0hQ=", "webp", 512)
    # Rails' stale?(etag: @user) is a weak validator over the user's cache key.
    tag = avatar_key == "" ? "W/\"avatar-user-#{user_id}-#{fallback.version}\"" : "W/\"avatar-#{avatar_key}\""
    etag(tag)
    # Users::AvatarsController includes ActiveStorage::Streaming (ActionController::Live): no default headers.
    headers "Cache-Control" => "public, max-age=1800, stale-while-revalidate=604800", "X-Rack-Defaults" => "live"
    if avatar_key == ""
      if fallback.bot
        # send_file like Rails, so the response names default-bot-avatar.svg in its Content-Disposition.
        send_file(file_path(:default_bot_avatar_file), content_type: "image/svg+xml", disposition: :inline)
      else
        long_initials = fallback.initials.length >= 3
        index = crc32(user_id.to_s) % 18
        color = if index == 0
                  "#AF2E1B"
                elsif index == 1
                  "#CC6324"
                elsif index == 2
                  "#3B4B59"
                elsif index == 3
                  "#BFA07A"
                elsif index == 4
                  "#ED8008"
                elsif index == 5
                  "#ED3F1C"
                elsif index == 6
                  "#BF1B1B"
                elsif index == 7
                  "#736B1E"
                elsif index == 8
                  "#D07B53"
                elsif index == 9
                  "#736356"
                elsif index == 10
                  "#AD1D1D"
                elsif index == 11
                  "#BF7C2A"
                elsif index == 12
                  "#C09C6F"
                elsif index == 13
                  "#698F9C"
                elsif index == 14
                  "#7C956B"
                elsif index == 15
                  "#5D618F"
                elsif index == 16
                  "#3B3633"
                else
                  "#67695E"
                end
        render :avatar_initials, layout: nil, content_type: "image/svg+xml; charset=utf-8",
               locals: { initials: fallback.initials, color: color, long_initials: long_initials }
      end
    else
      key = avatar_key
      first = key[0, 2].to_s
      second = key[2, 2].to_s
      path = "#{storage}/#{first}/#{second}/#{key}"
      send_file(path, content_type: "image/webp", disposition: :inline)
    end
  end
end
