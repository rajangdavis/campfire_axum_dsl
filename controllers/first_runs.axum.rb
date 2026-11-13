controller do

  layout_locals do
    signed_in = false
    user_id = ""
    user_name = ""
  end

  def show
    return redirect("/") if account_count > 0
    # fresh_account_logo_path with no account: `v:` is nil, so the icon links carry no query (views/layout_no_account.html).
    render :first_run, layout: :layout_no_account, locals: { title: "Set up Campfire" }
  end

  # FirstRunsController#create: FirstRun.create! then start_new_session_for and `redirect_to root_url`. The room's
  # creator is saved with it; the administrator's after_create_commit (grant_membership_to_open_rooms), the room's
  # after_save_commit (grant_access_to_all_users) and `room.memberships.grant_to administrator` all insert the same
  # one membership, the open room's default involvement, so one insert stands for the three. A RecordNotUnique (two
  # set-ups racing) redirects to / as Rails' rescue does: the account check inside the transaction makes the loser a no-op.
  params :FirstRunCreate do
    field :name, :string, in: :form, name: "user[name]"
    field :email_address, :string, in: :form, name: "user[email_address]"
    field :password, :string, in: :form, name: "user[password]"
    field :avatar, :upload, in: :form, name: "user[avatar]"
  end

  def create
    return redirect("/") if account_count > 0
    token = random_token
    started = create_first_run(params[:name], params[:email_address], params[:password], params[:avatar], token, request_ip, user_agent)
    return halt(500, "the session was not started") if started != 1
    set_cookie :session_token, token, http_only: true, same_site: :lax, permanent: true
    redirect("/")
  end
end
