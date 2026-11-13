controller do

  layout_locals do
    signed_in = true
    user_id = current_user.id
    user_name = current_user.name
    logo_version = account_logo_version || ""
  end

  # Users::ProfilesController#show (users/profiles/show.html.erb): the signed-in user's own profile form, their rooms with
  # a notification button each, and the sign-in link.

  # Users::ProfilesController#update: `@user.update user_params` with `params.require(:user).permit(:name, :avatar,
  # :email_address, :password, :bio).compact`. The profile page has three forms (the avatar picker twice, and the
  # name/email/password/bio form), each sending only its own keys, so a key that is absent is left as it is. A blank
  # password is ignored (has_secure_password). updated_at moves only when a value changed or an avatar was attached.
  params :ProfileUpdate do
    field :name, :string, in: :form, name: "user[name]", optional: true
    field :email_address, :string, in: :form, name: "user[email_address]", optional: true
    field :password, :string, in: :form, name: "user[password]", optional: true
    field :bio, :string, in: :form, name: "user[bio]", optional: true
    field :avatar, :upload, in: :form, name: "user[avatar]"
  end

  # `redirect_to user_profile_url, notice: update_notice`: the avatar notice when a file was sent, else "✓", which GET
  # /users/me/profile shows once.
  # The avatar's variant is not made (the DSL has no image processing), so the new avatar shows as the initials until then.
  def update
    avatar = params[:avatar]
    saved_rows = save_profile(current_user.id, params[:name], params[:email_address], params[:password], params[:bio], avatar)
    return halt(404, "") if saved_rows != 1
    return redirect("/users/me/profile", notice: :notice_avatar) unless avatar.nil?
    redirect("/users/me/profile", notice: :notice_saved)
  end

  def show
    # The notice of the update above, shown once (see GET /account/edit): "✓", or the avatar one.
    flash = take_flash
    me = profile_user(id: current_user.id) || raise("the user was not read back")
    flags = current_flags
    shared = profile_memberships(user_id: current_user.id, direct: 0)
    directs = profile_memberships(user_id: current_user.id, direct: 1)
    transfer_url = "#{request_base_url}/session/transfers/#{rails_signed_id_for(current_user.id, purpose: "user/transfer", secret: :secret_key, expires_in: 14400)}"
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip
    # link_back: the referrer, or the root when there is none or it is this page's own URL.
    referrer = request_referrer
    back_url = referrer.empty? || referrer == "#{request_base_url}/users/me/profile" ? "/" : referrer
    render :user_profile, from: me, locals: { title: me.name, flash_on: flash.on, flash_alert: flash.alert, flash_text: flash.text, both: !shared.empty? && !directs.empty?, qr_id: urlsafe_base64(transfer_url), pwa_browser: pwa_browser(user_agent), pwa_os: pwa_os(user_agent), pwa_sc_ios: pwa_flag(user_agent, "sc_ios"), pwa_ff_android: pwa_flag(user_agent, "ff_android"), pwa_safari_desktop: pwa_flag(user_agent, "safari_desktop"), pwa_install_hidden: pwa_flag(user_agent, "install_hidden"), pwa_edge: pwa_flag(user_agent, "edge") }
  end
end
