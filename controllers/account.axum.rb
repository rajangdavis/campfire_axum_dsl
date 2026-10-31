fragment do
  # AccountsController#edit: the account settings page. A member sees the account and its people; an
  # administrator also gets the name/logo/restriction forms and the bots and custom-styles links.
  get "/account/edit", description: "Account settings" do
    user = current(:user)
    # The notice of AccountsController#update (`redirect_to edit_account_url, notice: "✓"`) travels in the _campfire_session
    # cookie's value as a ".notice_saved" suffix on the session token (see rooms.axum.rb for the alert); it is shown once
    # and the bare token is written back.
    session = cookie(:_campfire_session, signed: false).to_s
    saved = session.end_with?(".notice_saved")
    token = saved ? session[0, session.length - 13].to_s : session
    set_cookie :_campfire_session, token, signed: false
    page = account_page || raise("the account was not read back")
    account_settings_row = account_settings || raise("the account settings were not read back")
    flags = body_flags(user_id: user.id) || raise("the account flags were not read back")
    admin = flags.admin == 1
    include_banned = admin ? 1 : 0
    administrators = account_users(role: 1, include_banned: include_banned, user_id: user.id)
    members = account_users(role: 0, include_banned: include_banned, user_id: user.id)
    back_room_id = last_form_room_id(user_id: user.id, saved: cookie(:last_room, signed: false).to_s.to_i) || 0
    join_url = "#{request_base_url}/join/#{page.join_code}"
    body_class = "#{admin ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    has_administrators = !administrators.empty?
    has_members = !members.empty?
    both_users = has_administrators ? has_members : false
    render :account_edit, locals: { title: "Account settings", body_class: body_class, vapid_key: setting(:vapid_public_key), logo_version: page.logo_version, signed_in: true, user_id: user.id, user_name: user.name, flash_on: saved, flash_alert: false, flash_text: saved ? "✓" : "", name: page.name, join_url: join_url, qr_id: urlsafe_base64(join_url), account_form_action: "/account.#{page.id}", restrict_room_creation: account_settings_row.restrict_room_creation, restrict_room_creation_off: !account_settings_row.restrict_room_creation, has_logo: account_settings_row.has_logo, can_administer: admin, administrators: administrators, members: members, both_users: both_users, back_url: back_room_id > 0 ? "/rooms/#{back_room_id}" : "/", version: setting(:app_version) }
  end

  # Accounts::BotsController#index: every active bot and the curl commands for each room it posts to.
  get "/account/bots", description: "Chat bots" do
    user = current(:user)
    page = account_page || raise("the account was not read back")
    flags = body_flags(user_id: user.id) || raise("the account flags were not read back")
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    render :account_bots, locals: { title: "Chat bots", body_class: body_class, vapid_key: setting(:vapid_public_key), logo_version: page.logo_version, signed_in: true, user_id: user.id, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "", bots: account_bots, base_url: request_base_url }
  end

  # Accounts::BotsController#new: an empty bot form.
  get "/account/bots/new", description: "New chat bot" do
    user = current(:user)
    page = account_page || raise("the account was not read back")
    flags = body_flags(user_id: user.id) || raise("the account flags were not read back")
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    render :account_bot_new, locals: { title: "New chat bot", body_class: body_class, vapid_key: setting(:vapid_public_key), logo_version: page.logo_version, signed_in: true, user_id: user.id, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "", avatar_attached: false }
  end

  # Accounts::BotsController#edit: the bot's form, delete button and key-reset button.
  get "/account/bots/:id/edit", params: :BotPath, description: "Edit a chat bot" do
    user = current(:user)
    page = account_page || raise("the account was not read back")
    flags = body_flags(user_id: user.id) || raise("the account flags were not read back")
    bot = account_bot(id: params[:id]) || raise("no such bot")
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    render :account_bot_edit, locals: { title: "Edit bot", body_class: body_class, vapid_key: setting(:vapid_public_key), logo_version: page.logo_version, signed_in: true, user_id: user.id, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "", bot_id: bot.id, name: bot.name, has_name: !bot.name.empty?, base_url: request_base_url, avatar_blob_id: bot.avatar_blob_id || 0, avatar_filename: bot.avatar_filename, avatar_attached: bot.avatar_attached, webhook_url: bot.webhook_url, has_webhook: !bot.webhook_url.empty? }
  end

  # AccountsController#update, reached by the form as `POST /account.<id>` with `_method=patch` (`account_path(@account)`
  # on the singular resource writes the account's id where the format goes, so `:id` here is that segment, not a lookup).
  # The name form is the one built: the logo upload and the restrict-room-creation switch send the same verb with other
  # keys and are not handled.
  params :AccountUpdate do
    field :id, :string, in: :path
    field :name, :string, in: :form, name: "account[name]"
  end

  # `@account.update!(name:)`: updated_at moves only when the name changed (the logo's `?v=` is the account's updated_at).
  execute :rename_account, args: { name: :string }, sql: <<~SQL
    UPDATE accounts SET
      updated_at = CASE WHEN name <> :name THEN strftime('%Y-%m-%d %H:%M:%f', 'now') ELSE updated_at END,
      name = :name
  SQL

  # ensure_can_administer (`head :forbidden`), update!, then `redirect_to edit_account_url, notice: "✓"`; the notice is
  # carried as in GET /account/edit above.
  patch "/account.:id", params: :AccountUpdate, description: "Rename the account and go back to its settings with a notice" do
    user = current(:user)
    flags = body_flags(user_id: user.id) || raise("the account flags were not read back")
    return halt(403, "") unless flags.admin == 1
    rename_account(name: params[:name])
    session = cookie(:_campfire_session, signed: false).to_s
    set_cookie :_campfire_session, "#{session}.notice_saved", signed: false
    redirect("/account/edit")
  end

  # Accounts::CustomStylesController#edit: the account's custom CSS.
  get "/account/custom_styles/edit", description: "Custom styles" do
    user = current(:user)
    page = account_page || raise("the account was not read back")
    flags = body_flags(user_id: user.id) || raise("the account flags were not read back")
    account_settings_row = account_settings || raise("the account settings were not read back")
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    render :account_custom_styles, locals: { title: "Custom styles", body_class: body_class, vapid_key: setting(:vapid_public_key), logo_version: page.logo_version, signed_in: true, user_id: user.id, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "", custom_styles: account_settings_row.custom_styles, custom_styles_action: "#{request_base_url}/account/custom_styles" }
  end
end
