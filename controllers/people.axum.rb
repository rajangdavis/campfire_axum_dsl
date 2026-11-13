controller do
  # Users::BansController and Users::AvatarsController#destroy: an administrator bans or unbans a person; anyone removes
  # their own avatar.

  params :UserBanPath do
    field :id, :i64, in: :path
  end

  # Users::BansController#create: ensure_can_administer (403), `User.find` (404), User#ban -- the bans, the person's
  # cable connections closed, their sessions deleted, their messages removed (RemoveBannedContentJob, run here in the
  # request), status banned -- then redirect_to @user.
  def ban
    flags = current_flags
    return head(403) unless flags.admin == 1
    target = user_exists(id: params[:id])
    return html(file_text(:page_404), status: 404, content_type: "text/html; charset=UTF-8") if target.nil?
    return html(file_text(:page_422), status: 422, content_type: "text/html; charset=UTF-8") if private_session_ip_count(user_id: params[:id]) > 0
    gone = user_messages(user_id: params[:id])
    banned = ban_user(params[:id])
    return html(file_text(:page_404), status: 404, content_type: "text/html; charset=UTF-8") if banned != 1
    gone.each { |m| broadcast_remove_to(global_id_param(m.room_class, m.room_id, app: "campfire"), :messages, target: "message_#{m.param}") }
    redirect("/users/#{params[:id]}")
  end

  # Users::BansController#destroy: ensure_can_administer, `User.find` (404), User#unban (the bans go, status active),
  # redirect_to @user.
  def unban
    flags = current_flags
    return head(403) unless flags.admin == 1
    target = user_exists(id: params[:id])
    return html(file_text(:page_404), status: 404, content_type: "text/html; charset=UTF-8") if target.nil?
    unbanned = unban_user(params[:id])
    return html(file_text(:page_404), status: 404, content_type: "text/html; charset=UTF-8") if unbanned != 1
    redirect("/users/#{params[:id]}")
  end

  params :AvatarOwnerPath do
    field :token, :string, in: :path
  end

  # Users::AvatarsController#destroy: always the signed-in person's own avatar (the path's id is not read), then
  # redirect_to user_profile_url.
  def destroy_avatar
    blob = user_avatar_blob_id(user_id: current_user.id)
    return redirect("/users/me/profile") if blob.nil? # `avatar.destroy` on no attachment does nothing
    purged = purge_user_avatar(current_user.id, blob)
    return halt(500, "the avatar was not removed") if purged != 1
    redirect("/users/me/profile")
  end
end
