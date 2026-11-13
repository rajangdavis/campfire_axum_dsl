controller do
  # QrCodeController#show (allow_unauthenticated_access): the id is the url-safe Base64 of the URL to encode (the
  # profile page's transfer link). The SVG is rqrcode's `as_svg(viewbox: true, fill: :white, color: :black)`, public for
  # a year (`expires_in 1.year, public: true`), with the weak ETag Rack::ETag adds. Base64.urlsafe_decode64 raises on a
  # malformed id (a 500 in Rails); a URL too long for a version 40 code makes rqrcode raise as well.
  def show
    url = urlsafe_decode64(params[:id])
    return halt(500, "") if url.nil?
    svg = qr_code_svg(url)
    return halt(500, "") if svg.nil?
    etag("W/\"qr-#{crc32(svg)}\"")
    headers "Cache-Control" => "max-age=31556952, public", "X-Rack-Defaults" => "unauthenticated"
    text(svg, content_type: "image/svg+xml; charset=utf-8")
  end
end
