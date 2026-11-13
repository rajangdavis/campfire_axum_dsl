# Accounts::BotsController: the chat bots an administrator manages.
controller do

  layout_locals do
    signed_in = true
    user_id = current_user.id
    user_name = current_user.name
  end

  before :ensure_can_administer

  params :BotForm do
    field :name, :string, in: :form, name: "user[name]", default: ""
    field :webhook_url, :string, in: :form, name: "user[webhook_url]", optional: true
    field :avatar, :upload, in: :form, name: "user[avatar]"
  end

  params :BotUpdate do
    field :name, :string, in: :form, name: "user[name]", default: ""
    field :webhook_url, :string, in: :form, name: "user[webhook_url]", optional: true
    field :avatar, :upload, in: :form, name: "user[avatar]"
  end

  # Accounts::BotsController#index: every active bot and the curl commands for each room it posts to.
  def index
    page = account_page || raise("the account was not read back")
    flags = account_flags
    body_class = account_body_class(flags)
    render :account_bots, locals: { title: "Chat bots", logo_version: page.logo_version, bots: account_bots, base_url: request_base_url }
  end

  # Accounts::BotsController#new: an empty bot form.
  def new
    page = account_page || raise("the account was not read back")
    flags = account_flags
    body_class = account_body_class(flags)
    render :account_bot_new, locals: { title: "New chat bot", logo_version: page.logo_version, avatar_attached: false }
  end

  # Accounts::BotsController#edit: the bot's form, delete button and key-reset button.
  def edit
    page = account_page || raise("the account was not read back")
    flags = account_flags
    bot = account_bot(id: params[:id])
    return not_found if bot.nil? # User.active_bots.find: RecordNotFound
    body_class = account_body_class(flags)
    render :account_bot_edit, from: bot, locals: { title: "Edit bot", logo_version: page.logo_version, bot_id: bot.id, has_name: !bot.name.empty?, base_url: request_base_url, avatar_blob_id: bot.avatar_blob_id || 0, has_webhook: !bot.webhook_url.empty? }
  end

  # Accounts::BotsController#create: ensure_can_administer, User.create_bot!(name, avatar, webhook_url)
  # (models/bot.axum.rb), redirect_to account_bots_url.
  def create
    create_bot(params[:name], params[:webhook_url], params[:avatar])
    redirect("/account/bots")
  end

  # Accounts::BotsController#update: User.active_bots.find (404), update_bot! (models/bot.axum.rb), redirect_to
  # account_bots_url.
  def update
    found = active_bot_id(id: params[:id])
    return not_found if found.nil?
    saved = update_bot(params[:id], params[:name], params[:webhook_url], params[:avatar])
    return not_found if saved != 1
    redirect("/account/bots")
  end

  # Accounts::BotsController#destroy: User.active_bots.find (404), deactivate (as an account member's removal: its
  # non-direct memberships, push subscriptions, searches and sessions go, status deactivated; a bot has no address, so
  # the -deactivated- rewrite leaves NULL), redirect_to account_bots_url. The webhook stays.
  def destroy
    found = active_bot_id(id: params[:id])
    return not_found if found.nil?
    deactivated = deactivate_user(params[:id])
    return not_found if deactivated != 1
    redirect("/account/bots")
  end
end
