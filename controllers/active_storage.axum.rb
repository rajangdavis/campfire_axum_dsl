controller do
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

  # Blobs::RedirectController#show: `expires_in ActiveStorage.service_urls_expire_in` (five minutes, private), then
  # `redirect_to @blob.url(disposition:), allow_other_host: true`: the original blob, no variant. As for the
  # representation redirect, the answer carries the session cookie (the "write_session" marker). A bad signature is
  # `head :not_found`.
  def blob_redirect
    blob_id = active_storage_verified_id(params[:signed_blob_id], secret: :secret_key)
    return halt(404, "") if blob_id.nil?
    blob = blob_file(id: blob_id)
    return halt(404, "") if blob.nil?
    path = active_storage_disk_path(blob.key, blob.filename, blob.content_type || "application/octet-stream", secret: :secret_key)
    headers "Location" => "#{request_base_url}#{path}", "Cache-Control" => "max-age=300, private",
            "Content-Type" => "text/html; charset=utf-8", "X-Rack-Defaults" => "engine, write_session"
    halt(302, "")
  end

  # Representations::RedirectController#show: `expires_in ActiveStorage.service_urls_expire_in` (five minutes, private),
  # then `redirect_to image.url(disposition:), allow_other_host: true`: an absolute URL to the disk service. A bad
  # signature is `head :not_found`.
  def representation_redirect
    blob_id = active_storage_verified_id(params[:signed_blob_id], secret: :secret_key)
    return halt(404, "") if blob_id.nil?
    # A blob with no variant record (an upload whose :thumb could not be made, such as a video, whose preview needs
    # ffmpeg) answers its original file: a 404 here leaves a 0x0 broken <img> the page never shows.
    record_poster_marker(id: blob_id)
    record_poster_blob(id: blob_id)
    record_poster_attachment(id: blob_id)
    image = blob_representation(id: blob_id)
    blob = blob_file(id: blob_id)
    return halt(404, "") if blob.nil?
    path = active_storage_disk_path(image&.key || blob.key, image&.filename || blob.filename, image&.content_type || (blob.content_type || "application/octet-stream"), secret: :secret_key)
    headers "Location" => "#{request_base_url}#{path}", "Cache-Control" => "max-age=300, private",
            "Content-Type" => "text/html; charset=utf-8", "X-Rack-Defaults" => "engine, write_session"
    halt(302, "")
  end

  # DiskController#show, plus the initializer's `after_action` cache header (`max-age=3600, public`): the blob's file,
  # inline, named by the signed disposition. The key must verify and not have expired.
  def disk
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

  params :DirectUploadBlob do
    field :filename, :string
    field :byte_size, :i64
    field :checksum, :string
    field :content_type, :string, optional: true
  end

  params :DirectUpload do
    # Rails' `params.expect(blob: [...])`; `blob` is a DSL word, so the body reads it as params[:blob].
    field :blob, :DirectUploadBlob, in: :body
  end

  # DirectUploadsController#create: `ActiveStorage::Blob.create_before_direct_upload!(**blob_args)` and
  # `render json: blob.as_json(root: false, methods: :signed_id).merge(direct_upload: {url:, headers:})`, the url
  # being DiskService#url_for_direct_upload (absolute, five minutes) and the headers `{"Content-Type" => content_type}`.
  def direct_upload
    return head(401) if session_for_cookie(token: cookie(:session_token).to_s).nil?
    content_type = params[:blob].content_type || ""
    key = active_storage_key
    row = create_direct_upload_blob(key: key, filename: params[:blob].filename, content_type: content_type, byte_size: params[:blob].byte_size, checksum: params[:blob].checksum) || raise("the blob was not written")
    url = "#{request_base_url}#{active_storage_direct_upload_url(key, content_type, params[:blob].byte_size, params[:blob].checksum, secret: :secret_key)}"
    body = json_object("id" => row.id, "key" => key, "filename" => params[:blob].filename, "content_type" => content_type,
                       "metadata" => json_object(), "service_name" => "local", "byte_size" => params[:blob].byte_size,
                       "checksum" => params[:blob].checksum, "created_at" => row.created_at,
                       "signed_id" => active_storage_blob_id(row.id, secret: :secret_key),
                       "direct_upload" => json_object("url" => url, "headers" => json_object("Content-Type" => content_type)))
    text(body, content_type: "application/json; charset=utf-8")
  end

  params :DiskUpload do
    field :encoded_token, :string, in: :path
  end

  # DiskController#update: the token's key, content type, length and checksum decide (204, 404, 422).
  def disk_upload
    return head(401) if session_for_cookie(token: cookie(:session_token).to_s).nil?
    status = active_storage_disk_upload(params[:encoded_token], setting(:storage), secret: :secret_key)
    return head(204) if status == 204
    return head(404) if status == 404
    return head(422) if status == 422
    head(500)
  end
end
