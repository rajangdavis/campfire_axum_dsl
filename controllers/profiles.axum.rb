fragment do
  # Users::ProfilesController#show (users/profiles/show.html.erb): the signed-in user's own profile form, their rooms with
  # a notification button each, and the sign-in link.

  # Current.user as the form fills it in; avatar_attached says whether an avatar blob is attached (the delete button).
  record :ProfileUser do
    field :name, :string
    field :email, :string
    field :bio, :string
    field :version, :string
    field :avatar_attached, :bool
  end

  query :profile_user, args: { id: :i64 }, returns: :ProfileUser?, sql: <<~SQL
    SELECT name, COALESCE(email_address, '') AS email, COALESCE(bio, '') AS bio,
           strftime('%Y%m%d%H%M%S', updated_at) AS version,
           EXISTS (SELECT 1 FROM active_storage_attachments WHERE record_type = 'User' AND record_id = users.id AND name = 'avatar') AS avatar_attached
    FROM users WHERE id = :id
  SQL

  # One row of `Current.user.memberships.with_ordered_room` (LOWER(rooms.name), then the room), the shared rooms or the
  # direct ones. label is room_display_name(room, for_user:) (a direct room is named after the other people in it);
  # next_involvement and text are Rooms::InvolvementsHelper's, the bell flags choose the icon.
  record :ProfileMembership do
    field :room_id, :i64
    field :kind, :string
    field :label, :string
    field :involvement, :string
    field :next_involvement, :string
    field :text, :string
    field :bell_mentions, :bool
    field :bell_everything, :bool
    field :bell_nothing, :bool
    field :bell_invisible, :bool
  end

  query :profile_memberships, args: { user_id: :i64, direct: :i64 }, returns: list(:ProfileMembership), sql: <<~SQL
    SELECT room_id, kind, label, involvement,
           CASE WHEN kind = 'direct' THEN CASE WHEN involvement = 'everything' THEN 'nothing' ELSE 'everything' END
                ELSE CASE involvement WHEN 'mentions' THEN 'everything' WHEN 'everything' THEN 'nothing' WHEN 'nothing' THEN 'invisible' ELSE 'mentions' END END AS next_involvement,
           CASE involvement WHEN 'mentions' THEN 'Notifying about @ mentions' WHEN 'everything' THEN 'Notifying about all messages'
                WHEN 'nothing' THEN 'Notifications are off' ELSE 'Notifications are off and room invisible in sidebar' END AS text,
           involvement = 'mentions' AS bell_mentions, involvement = 'everything' AS bell_everything,
           involvement = 'nothing' AS bell_nothing, involvement = 'invisible' AS bell_invisible
    FROM (
      SELECT r.id AS room_id,
             CASE r.type WHEN 'Rooms::Open' THEN 'open' WHEN 'Rooms::Closed' THEN 'closed' ELSE 'direct' END AS kind,
             CASE WHEN r.type = 'Rooms::Direct' THEN COALESCE(
               (SELECT CASE WHEN o.cnt = 1 THEN o.s
                            ELSE substr(o.s, 1, length(o.s) - length(o.last_name) - 2)
                                 || CASE o.cnt WHEN 2 THEN ' and ' ELSE ', and ' END || o.last_name END
                FROM (SELECT COUNT(*) AS cnt, group_concat(n.name, ', ') AS s,
                             (SELECT u2.name FROM memberships m2 JOIN users u2 ON u2.id = m2.user_id
                              WHERE m2.room_id = r.id AND m2.user_id <> :user_id ORDER BY u2.id DESC LIMIT 1) AS last_name
                      FROM (SELECT u.name AS name FROM memberships m3 JOIN users u ON u.id = m3.user_id
                            WHERE m3.room_id = r.id AND m3.user_id <> :user_id ORDER BY u.id) AS n) AS o
                WHERE o.cnt > 0),
               (SELECT name FROM users WHERE id = :user_id))
             ELSE COALESCE(r.name, '') END AS label,
             COALESCE(m.involvement, 'mentions') AS involvement,
             r.name AS sort_name, m.id AS membership_id
      FROM memberships m JOIN rooms r ON r.id = m.room_id
      WHERE m.user_id = :user_id AND (r.type = 'Rooms::Direct') = (:direct = 1)
    )
    ORDER BY LOWER(sort_name), membership_id
  SQL

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

  execute :update_profile, args: { id: :i64, has_name: :i64, name: :string, has_email: :i64, email: :string, has_bio: :i64, bio: :string, has_password: :i64, digest: :string }, sql: <<~SQL
    UPDATE users SET
      updated_at = CASE WHEN (:has_name = 1 AND name <> :name) OR (:has_email = 1 AND COALESCE(email_address, '') <> :email)
                          OR (:has_bio = 1 AND COALESCE(bio, '') <> :bio) OR :has_password = 1
                        THEN strftime('%Y-%m-%d %H:%M:%f', 'now') ELSE updated_at END,
      name = CASE WHEN :has_name = 1 THEN :name ELSE name END,
      email_address = CASE WHEN :has_email = 1 THEN :email ELSE email_address END,
      bio = CASE WHEN :has_bio = 1 THEN :bio ELSE bio END,
      password_digest = CASE WHEN :has_password = 1 THEN :digest ELSE password_digest END
    WHERE id = :id
  SQL

  # `redirect_to user_profile_url, notice: update_notice`: the avatar notice when a file was sent, else "✓". The notice is
  # carried in the _campfire_session cookie's value as a suffix (".notice_avatar" or ".notice_saved"), as in GET /account/edit.
  # The avatar's variant is not made (the DSL has no image processing), so the new avatar shows as the initials until then.
  patch "/users/me/profile", params: :ProfileUpdate, description: "Save the profile (and an avatar) and go back to it with a notice" do
    user = current(:user)
    avatar = params[:avatar]
    password = params[:password] || ""
    digest = password.empty? ? "" : Bcrypt.hash(password)
    has_name = params[:name].nil? ? 0 : 1
    has_email = params[:email_address].nil? ? 0 : 1
    has_bio = params[:bio].nil? ? 0 : 1
    has_password = password.empty? ? 0 : 1
    name = params[:name] || ""
    email = params[:email_address] || ""
    bio = params[:bio] || ""
    file_name = avatar&.filename || ""
    file_type = avatar&.content_type || ""
    file_size = avatar&.size || 0
    file_checksum = avatar&.checksum || ""
    notice = avatar.nil? ? ".notice_saved" : ".notice_avatar"
    key = if avatar.nil?
      ""
    else
      avatar.store(setting(:storage))
    end
    saved_rows = transaction do
      insert_blob(key: key, filename: file_name, content_type: file_type, metadata: "{\"identified\":true}", byte_size: file_size, checksum: file_checksum)
      detach_user_avatar(user_id: user.id, key: key)
      attach_user_avatar(user_id: user.id, key: key)
      touch_user_for_avatar(user_id: user.id, key: key)
      update_profile(id: user.id, has_name: has_name, name: name, has_email: has_email, email: email, has_bio: has_bio, bio: bio, has_password: has_password, digest: digest)
    end
    return halt(404, "") if saved_rows != 1
    session = cookie(:_campfire_session, signed: false).to_s
    set_cookie :_campfire_session, "#{session}#{notice}", signed: false
    redirect("/users/me/profile")
  end

  get "/users/me/profile", description: "Your profile" do
    user = current(:user)
    # The notice of the update above, shown once (see GET /account/edit): "✓", or the avatar one.
    session = cookie(:_campfire_session, signed: false).to_s
    saved = session.end_with?(".notice_saved")
    avatar_saved = session.end_with?(".notice_avatar")
    token = saved ? session[0, session.length - 13].to_s : (avatar_saved ? session[0, session.length - 14].to_s : session)
    set_cookie :_campfire_session, token, signed: false
    me = profile_user(id: user.id) || raise("the user was not read back")
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    shared = profile_memberships(user_id: user.id, direct: 0)
    directs = profile_memberships(user_id: user.id, direct: 1)
    transfer_url = "#{request_base_url}/session/transfers/#{rails_signed_id_for(user.id, purpose: "user/transfer", secret: :secret_key, expires_in: 14400)}"
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    render :user_profile, locals: { title: me.name, body_class: body_class, vapid_key: setting(:vapid_public_key), logo_version: account_logo_version || "", signed_in: true, user_id: user.id, user_name: user.name, flash_on: saved || avatar_saved, flash_alert: false, flash_text: saved ? "✓" : (avatar_saved ? "It may take up to 30 minutes to change everywhere." : ""), back_url: "/", name: me.name, email: me.email, bio: me.bio, version: me.version, avatar_attached: me.avatar_attached, shared: shared, directs: directs, both: !shared.empty? && !directs.empty?, transfer_url: transfer_url, qr_id: urlsafe_base64(transfer_url), pwa_browser: pwa_browser(user_agent), pwa_os: pwa_os(user_agent), pwa_sc_ios: pwa_flag(user_agent, "sc_ios"), pwa_ff_android: pwa_flag(user_agent, "ff_android"), pwa_safari_desktop: pwa_flag(user_agent, "safari_desktop"), pwa_install_hidden: pwa_flag(user_agent, "install_hidden"), pwa_edge: pwa_flag(user_agent, "edge") }
  end
end
