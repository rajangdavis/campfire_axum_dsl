fragment do
  # PwaController (allow_unauthenticated_access, skip_forgery_protection): the web app manifest and the service worker.
  get "/webmanifest.json", description: "Web app manifest", skip: [:authenticate] do
    acct = account_page
    return halt(500, "no account") if acct.nil?
    render :manifest, layout: nil, content_type: "application/json; charset=utf-8", locals: { name: acct.name, logo_version: acct.logo_version, origin: request_base_url }
  end

  get "/service-worker.js", description: "Service worker", skip: [:authenticate] do
    text(file_text(:service_worker), content_type: "text/javascript; charset=utf-8")
  end
end
