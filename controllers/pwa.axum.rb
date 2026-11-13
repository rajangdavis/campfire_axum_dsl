controller do
  # PwaController (allow_unauthenticated_access, skip_forgery_protection): the web app manifest and the service worker.
  def manifest
    # Before the first run there is no account: Rails' `Current.account&.name || "Campfire"`, and
    # fresh_account_logo_path leaves `v` off when the account's updated_at is nil.
    acct = account_page
    name = acct.nil? ? "Campfire" : acct.name
    version = acct.nil? ? "" : acct.logo_version
    logo_src = version.empty? ? "/account/logo" : "/account/logo?v=#{version}"
    logo_small_src = version.empty? ? "/account/logo?size=small" : "/account/logo?size=small&v=#{version}"
    # PwaController allow_unauthenticated_access: the session is not resumed, so session_token is not written back.
    headers "X-Rack-Defaults" => "unauthenticated"
    render :manifest, layout: nil, content_type: "application/json; charset=utf-8", locals: { origin: request_base_url }
  end

  def service_worker
    headers "X-Rack-Defaults" => "unauthenticated"
    text(file_text(:service_worker), content_type: "text/javascript; charset=utf-8")
  end
end
