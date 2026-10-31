fragment do
  # UsersController#new: the join page. verify_join_code answers `head :not_found` for a code that is not the account's.
  get "/join/:join_code", params: :JoinPath, description: "The join form for an account's join code", skip: [:authenticate] do
    acct = account_page
    return text("", status: 404, content_type: "text/html") if acct.nil? || acct.join_code != params[:join_code]
    has_admin = acct.admin_email != ""
    render :users_new, locals: { title: "Sign up", vapid_key: setting(:vapid_public_key), join_code: acct.join_code, account_name: acct.name, logo_version: acct.logo_version, admin_name: acct.admin_name, admin_email: acct.admin_email, has_admin: has_admin, version: setting(:app_version), signed_in: false, user_id: "", user_name: "", flash_on: false, flash_alert: false, flash_text: "" }
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

  # has_secure_password stores the BCrypt digest (cost 12, Bcrypt.hash); role 0 is member and status 0 active (the defaults).
  query :create_user, args: { name: :string, email: :string, digest: :string }, returns: :i64, sql: <<~SQL
    INSERT INTO users (name, email_address, password_digest, role, status, created_at, updated_at)
    VALUES (:name, :email, :digest, 0, 0, strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now'))
    RETURNING id
  SQL

  # User#grant_membership_to_open_rooms (after_create_commit): Membership.insert_all over Rooms::Open, the default involvement.
  execute :grant_open_rooms_to, args: { user_id: :i64 }, sql: <<~SQL
    INSERT OR IGNORE INTO memberships (room_id, user_id, involvement, created_at, updated_at)
    SELECT id, :user_id, 'mentions', strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now')
    FROM rooms WHERE type = 'Rooms::Open' ORDER BY id
  SQL

  # The rows of the account's new person, an optional avatar with them, then the session cookie as POST /session writes it.
  # UsersController#create's `rescue ActiveRecord::RecordNotUnique` answers `redirect_to new_session_url(email_address:
  # user_params[:email_address])`: a taken address goes to the sign-in form with it prefilled. url_encode is the encoder
  # Rails builds that query with, and a redirect path may interpolate it because its output is ASCII by construction,
  # so no byte of it can be one a Location header rejects.
  post "/join/:join_code", params: :JoinCreate, description: "Create a person from the join form, sign them in and go to a room", skip: [:authenticate] do
    acct = account_page
    return text("", status: 404, content_type: "text/html") if acct.nil? || acct.join_code != params[:join_code]
    return redirect("/session/new?email_address=#{url_encode(params[:email_address])}") if user_email_taken(email: params[:email_address]) > 0
    avatar = params[:avatar]
    digest = Bcrypt.hash(params[:password])
    token = random_token
    session_token = "#{token}"
    ip = request_ip
    agent = user_agent
    file_name = avatar&.filename || ""
    file_type = avatar&.content_type || ""
    file_size = avatar&.size || 0
    file_checksum = avatar&.checksum || ""
    key = if avatar.nil?
      ""
    else
      avatar.store(setting(:storage))
    end
    started = transaction do
      id = create_user(name: params[:name], email: params[:email_address], digest: digest)
      grant_open_rooms_to(user_id: id)
      insert_blob(key: key, filename: file_name, content_type: file_type, metadata: "{\"identified\":true}", byte_size: file_size, checksum: file_checksum)
      attach_user_avatar(user_id: id, key: key)
      start_session(token: session_token, user_id: id, ip: ip, agent: agent)
    end
    return halt(500, "the session was not started") if started != 1
    set_cookie :session_token, token, http_only: true, same_site: :lax, permanent: true
    redirect("/")
  end

  # Sessions::TransfersController#show renders the auto-submitting form without looking the transfer up (#update does).
  # views/session_transfer.html deliberately leaves that form unclosed: Rails' auto_submit_form_with emits only the
  # opening tag, so the browser parses the rest of the layout inside it and drops the lightbox's nested
  # `<form method="dialog">` (the form-element-pointer rule). The live DOM comparison requires the same tree.
  get "/session/transfers/:id", params: :TransferPath, description: "The page that submits a session transfer", skip: [:authenticate] do
    render :session_transfer, locals: { title: "Campfire", logo_version: account_logo_version || "", vapid_key: setting(:vapid_public_key), transfer_id: params[:id], signed_in: false, user_id: "", user_name: "", flash_on: false, flash_alert: false, flash_text: "" }
  end

  # Sessions::TransfersController#update: the form's PUT. `User.active.find_by_transfer_id(params[:id])` is
  # `User.active.find_signed(id, purpose: :transfer)` (app/models/user/transferable.rb:5-8), a 4-hour signed id, so
  # an expired, tampered or wrong-purpose token is nil and answers `head :bad_request`. Rails takes that 400's content
  # type from the request format; the auto-submitting form's Accept is Turbo's, so the capture has an empty
  # `text/vnd.turbo-stream.html` (not text/html). A live one starts a session and redirects to post_authenticating_url;
  # this port does not keep Rails' return_to_after_authenticating (the `return_to` cookie), so the redirect is "/".
  put "/session/transfers/:id", params: :TransferPath, description: "Complete a session transfer and sign in", skip: [:authenticate] do
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

  # The user a page is about: role 2 is a bot and status 0 is active, 1 deactivated, 2 banned (user.rb enums).
  # version is User#updated_at.to_fs(:number), the `?v=` fresh_user_avatar_path writes.
  record :UserPageRow do
    field :id, :i64
    field :name, :string
    field :bio, :string
    field :email, :string
    field :role, :i64
    field :status, :i64
    field :version, :string
  end

  query :user_page_row, args: { id: :i64 }, returns: :UserPageRow?, sql: <<~SQL
    SELECT id, name, COALESCE(bio, '') AS bio, COALESCE(email_address, '') AS email, role, status,
           strftime('%Y%m%d%H%M%S', updated_at) AS version
    FROM users WHERE id = :id
  SQL

  # `User.find(params[:id])`. An administrator sees the sign-in link (users/profiles/_transfer, a 4-hour
  # `user.signed_id(purpose: :transfer, expires_in: 4.hours)` URL) of an active person, the email address and the ban
  # button; only an active bot or person can be pinged. link_back goes to the referrer, which this port does not read,
  # so the back link is the root, where Rails goes when there is none.
  get "/users/:id", params: :UserPath, description: "A user's page" do
    user = current(:user)
    page = user_page_row(id: params[:id])
    # User.find raises RecordNotFound, which production answers with public/404.html (controllers/errors.axum.rb).
    # ActionDispatch::PublicExceptions renders the page itself: its own Content-Type spelling, none of the stack's headers.
    return html(file_text(:page_404), status: 404, content_type: "text/html; charset=UTF-8") if page.nil?
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
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
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    render :user_show, locals: { title: page.name, body_class: body_class, vapid_key: setting(:vapid_public_key), logo_version: account_logo_version || "", signed_in: true, user_id: user.id, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "", back_url: "/", target_id: page.id, name: page.name, bio: page.bio, email: page.email, version: page.version, is_current: page.id == user.id, is_bot: is_bot, is_active: is_active, is_deactivated: page.status == 1, is_banned: page.status == 2, can_administer: can_administer, show_ban: can_administer && page.id != user.id, show_transfer: show_transfer, transfer_url: transfer_url, qr_id: qr_id }
  end
end
