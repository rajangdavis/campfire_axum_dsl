# AccountsController: the account settings page and its update (name, logo, room-creation switch).
controller do

  layout_locals do
    signed_in = true
    user_id = current_user.id
    user_name = current_user.name
  end

  before :ensure_can_administer, only: [:update]

  # AccountsController#edit: the account settings page. A member sees the account and its people; an
  # administrator also gets the name/logo/restriction forms and the bots and custom-styles links.
  def edit
    # The notice of AccountsController#update (`redirect_to edit_account_url, notice: "✓"`), shown once (the `flash`
    # declaration in campfire.axum.rb).
    flash = take_flash
    page = account_page || raise("the account was not read back")
    account_settings_row = account_settings || raise("the account settings were not read back")
    flags = account_flags
    admin = flags.admin == 1
    include_banned = admin ? 1 : 0
    administrators = account_users(role: 1, include_banned: include_banned, user_id: current_user.id)
    members = account_users(role: 0, include_banned: include_banned, user_id: current_user.id)
    back_room_id = last_form_room_id(current_user.id, cookie(:last_room, signed: false).to_s.to_i)
    join_url = "#{request_base_url}/join/#{page.join_code}"
    body_class = account_body_class(flags)
    has_administrators = !administrators.empty?
    has_members = !members.empty?
    both_users = has_administrators ? has_members : false
    # set_page_and_extract_portion_from users, per_page: 500: the page lists everyone, and a lazy frame loads page 2 when
    # there are more than 500 (geared_pagination's `@page.last?` is false).
    has_next_page = account_people_count(include_banned: include_banned) > 500
    render :account_edit, locals: { title: "Account settings", logo_version: page.logo_version, flash_on: flash.on, flash_alert: flash.alert, flash_text: flash.text, name: page.name, qr_id: urlsafe_base64(join_url), account_form_action: "/account.#{page.id}", restrict_room_creation: account_settings_row.restrict_room_creation, restrict_room_creation_off: !account_settings_row.restrict_room_creation, has_logo: account_settings_row.has_logo, can_administer: admin, back_url: back_room_id > 0 ? "/rooms/#{back_room_id}" : "/", version: setting(:app_version) }
  end

  # AccountsController#update, reached by the form as `POST /account.<id>` with `_method=patch` (`account_path(@account)`
  # on the singular resource writes the account's id where the format goes, so `:id` here is that segment, not a lookup).
  # The name form is the one built: the logo upload and the restrict-room-creation switch send the same verb with other
  # keys and are not handled.
  # AccountsController#update, reached by the forms as `POST /account.<id>` with `_method=patch` (the name and logo forms)
  # or `_method=put` (the restrict-room-creation switch): `account_path(@account)` on the singular resource writes the
  # account's id where the format goes, so `:id` here is that segment, not a lookup. Each form sends one of
  # `account[name]`, `account[logo]` and `account[settings][restrict_room_creation_to_administrators]`;
  # `@account.update!(account_params)` saves what came (a logo field with no file chosen is ignored), then
  # `redirect_to edit_account_url, notice: "✓"`, the notice carried as GET /account/edit carries it.
  # PATCH/PUT /account (Rails' `resource :account`); the form's `/account.873240054` is the same route with that number
  # as its format (use_layer :format_extension).
  params :AccountUpdate do
    field :name, :string, in: :form, name: "account[name]", optional: true
    field :logo, :upload, in: :form, name: "account[logo]"
    field :restrict, :string, in: :form, name: "account[settings][restrict_room_creation_to_administrators]", optional: true
  end

  def update
    name = params[:name]
    restrict = params[:restrict]
    logo = params[:logo]
    # `params.require(:account)`: a logo form sent with no file chosen leaves nothing under `account`, a 400.
    return halt(400, "") if name.nil? && restrict.nil? && logo.nil?
    update_account(name, restrict, logo)
    redirect("/account/edit", notice: :notice_saved)
  end
end
