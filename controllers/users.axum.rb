controller do

  # UsersController#new: the join page. verify_join_code answers `head :not_found` for a code that is not the account's.
  def new
    return redirect("/") unless signed_in_user_id(token: cookie(:session_token).to_s).nil?
    acct = account_page
    return text("", status: 404, content_type: "text/html") if acct.nil? || acct.join_code != params[:join_code]
    has_admin = acct.admin_email != ""
    render :users_new, from: acct, locals: { body_class: "signup #{account_logo_class}".strip, title: "Sign up", account_name: acct.name, has_admin: has_admin, version: setting(:app_version), signed_in: false, user_id: "", user_name: "" }
  end

  # UsersController#create: `User.create!(user_params)` (name, avatar, email_address, password), then
  # `start_new_session_for` and `redirect_to root_url`. verify_join_code answers `head :not_found` for a wrong code, as #new.
  # The form is multipart; with no file chosen the avatar input is an empty part and the upload is nil.
  params :JoinCreate do
    field :join_code, :string, in: :path
    field :name, :string, in: :form, name: "user[name]"
    field :email_address, :string, in: :form, name: "user[email_address]"
    field :password, :string, in: :form, name: "user[password]"
    field :avatar, :upload, in: :form, name: "user[avatar]"
  end

  # The rows of the account's new person, an optional avatar with them, then the session cookie as POST /session writes it.
  # UsersController#create's `rescue ActiveRecord::RecordNotUnique` answers `redirect_to new_session_url(email_address:
  # user_params[:email_address])`: a taken address goes to the sign-in form with it prefilled. url_encode is the encoder
  # Rails builds that query with, and a redirect path may interpolate it because its output is ASCII by construction,
  # so no byte of it can be one a Location header rejects.
  def create
    return redirect("/") unless signed_in_user_id(token: cookie(:session_token).to_s).nil?
    acct = account_page
    return text("", status: 404, content_type: "text/html") if acct.nil? || acct.join_code != params[:join_code]
    return redirect("/session/new?email_address=#{url_encode(params[:email_address])}") if user_email_taken(email: params[:email_address]) > 0
    token = random_token
    started = sign_up_user(params[:name], params[:email_address], params[:password], params[:avatar], token, request_ip, user_agent)
    return halt(500, "the session was not started") if started != 1
    set_cookie :session_token, token, http_only: true, same_site: :lax, permanent: true
    redirect("/")
  end

  # Sessions::TransfersController#show renders the auto-submitting form without looking the transfer up (#update does).
  # views/session_transfer.html deliberately leaves that form unclosed: Rails' auto_submit_form_with emits only the
  # opening tag, so the browser parses the rest of the layout inside it and drops the lightbox's nested
  # `<form method="dialog">` (the form-element-pointer rule). The live DOM comparison requires the same tree.
  def show_transfer
    render :session_transfer, locals: { body_class: account_logo_class, title: "Campfire", logo_version: account_logo_version || "", transfer_id: params[:id], signed_in: false, user_id: "", user_name: "" }
  end

  # Sessions::TransfersController#update: the form's PUT. `User.active.find_by_transfer_id(params[:id])` is
  # `User.active.find_signed(id, purpose: :transfer)` (app/models/user/transferable.rb:5-8), a 4-hour signed id, so
  # an expired, tampered or wrong-purpose token is nil and answers `head :bad_request`. Rails takes that 400's content
  # type from the request format; the auto-submitting form's Accept is Turbo's, so the capture has an empty
  # `text/vnd.turbo-stream.html` (not text/html). A live one starts a session and redirects to post_authenticating_url;
  # this port does not keep Rails' return_to_after_authenticating (the `return_to` cookie), so the redirect is "/".
  def update_transfer
    id = rails_signed_id(params[:id], purpose: "user/transfer", secret: :secret_key, check_expiry: true)
    return text("", status: 400, content_type: "text/vnd.turbo-stream.html") if id.nil?
    user = active_user_by_id(id: id)
    return text("", status: 400, content_type: "text/vnd.turbo-stream.html") if user.nil?
    token = random_token
    started = start_session(token: token, user_id: user.id, ip: request_ip, agent: user_agent)
    return halt(500, "the session was not started") if started != 1
    set_cookie :session_token, token, http_only: true, same_site: :lax, permanent: true
    redirect("/")
  end

  # --- UsersController#show (users/show.html.erb) ---------------------------------------------------------------

  params :UserPath do
    field :id, :i64, in: :path
  end

  # `User.find(params[:id])`. An administrator sees the sign-in link (users/profiles/_transfer, a 4-hour
  # `user.signed_id(purpose: :transfer, expires_in: 4.hours)` URL) of an active person, the email address and the ban
  # button; only an active bot or person can be pinged. link_back goes to the referrer, or the root when there is none
  # or it is this page's own URL.
  def show
    page = user_page_row(id: params[:id])
    # User.find raises RecordNotFound, which production answers with public/404.html (controllers/errors.axum.rb).
    # ActionDispatch::PublicExceptions renders the page itself: its own Content-Type spelling, none of the stack's headers.
    return html(file_text(:page_404), status: 404, content_type: "text/html; charset=UTF-8") if page.nil?
    flags = current_flags
    can_administer = flags.admin == 1
    is_bot = page.role == 2
    is_active = page.status == 0
    show_transfer = can_administer && is_active && !is_bot
    transfer_url = if show_transfer
      "#{request_base_url}/session/transfers/#{rails_signed_id_for(page.id, purpose: "user/transfer", secret: :secret_key, expires_in: 14400)}"
    else
      ""
    end
    qr_id = show_transfer ? urlsafe_base64(transfer_url) : ""
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip
    referrer = request_referrer
    back_url = referrer.empty? || referrer == "#{request_base_url}/users/#{params[:id]}" ? "/" : referrer
    render :user_show, from: page, locals: { title: page.name, logo_version: account_logo_version || "", signed_in: true, user_id: current_user.id, user_name: current_user.name, target_id: page.id, is_current: page.id == current_user.id, is_deactivated: page.status == 1, is_banned: page.status == 2, show_ban: can_administer && page.id != current_user.id }
  end
end
