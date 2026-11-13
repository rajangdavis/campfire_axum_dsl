# Accounts::UsersController: the people pages, and an administrator's role change and removal.
controller do
  before :ensure_can_administer, only: %i[update destroy]

  # The person's id in the path is derived by `resources :users` (routes.axum.rb), so this group has no fields of its own.
  params :AccountUserPath do
  end

  params :AccountUserRole do
    field :roles, list(:string), in: :form, name: "user[role]", default: []
  end

  params :AccountUsersPage do
    field :page, :i64, in: :query, default: 1
  end

  params :AccountUsersFormat do
    field :page, :i64, in: :query, default: 1
    field :format, :string, in: :query, optional: true
  end

  # Accounts::UsersController#update: ensure_can_administer, `User.active.find(params[:id])` (404 for anyone not active),
  # the role `params.require(:user)[:role].presence_in(%w[ member administrator ]) || "member"` (the checkbox's hidden
  # "member" and its "administrator" both arrive; the last wins), then redirect_to edit_account_url.
  def update
    existing = active_user_role(id: params[:id])
    return not_found if existing.nil? # User.active.find: RecordNotFound
    chosen = params[:roles].last || ""
    set_user_role(id: params[:id], role: chosen == "administrator" ? 1 : 0)
    redirect("/account/edit")
  end

  # Accounts::UsersController#destroy: ensure_can_administer, `User.active.find` (404), deactivate -- which first closes
  # the person's cable connections without a reconnect -- then redirect_to edit_account_url.
  def destroy
    existing = active_user_role(id: params[:id])
    return not_found if existing.nil? # User.active.find: RecordNotFound
    deactivated = deactivate_user(params[:id])
    return not_found if deactivated != 1
    redirect("/account/edit")
  end

  # Accounts::UsersController#index as the edit page's lazy frame asks for it (`format: :turbo_stream`): the page's people
  # replace the next_page_container frame, and unless geared_pagination calls the page the last one, a container for the
  # next page is appended. `last?` is `page == page_count` (at least one page), so a page past the end is empty and
  # still appends the one after it, as Rails answers.
  def index_stream
    flags = account_flags
    page = params[:page] < 1 ? 1 : params[:page]
    count = active_people_count
    pages = count == 0 ? 1 : (count + 499) / 500
    users = account_users_page(offset: (page - 1) * 500, user_id: current_user.id)
    render :account_users_page, layout: nil, content_type: "text/vnd.turbo-stream.html; charset=utf-8", locals: { can_administer: flags.admin == 1, has_next_page: page != pages, next_page: page + 1 }
  end

  # The same index without the extension: `?format=turbo_stream`, or a turbo-stream Accept, answers the page; any other
  # format is ActionController::UnknownFormat, which PublicExceptions answers 406 with an empty body.
  def index
    stream = params[:format].nil? ? turbo_stream_request? : params[:format].to_s == "turbo_stream"
    return text("", status: 406, content_type: "text/html; charset=UTF-8") unless stream
    flags = account_flags
    page = params[:page] < 1 ? 1 : params[:page]
    count = active_people_count
    pages = count == 0 ? 1 : (count + 499) / 500
    users = account_users_page(offset: (page - 1) * 500, user_id: current_user.id)
    render :account_users_page, layout: nil, content_type: "text/vnd.turbo-stream.html; charset=utf-8", locals: { can_administer: flags.admin == 1, has_next_page: page != pages, next_page: page + 1 }
  end
end
