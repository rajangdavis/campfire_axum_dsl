# Accounts::Bots::KeysController: a bot's new key.
controller do
  before :ensure_can_administer

  params :BotKeyPath do
    field :bot_id, :i64, in: :path
  end

  # Accounts::Bots::KeysController#update: ensure_can_administer, User.active_bots.find(params[:bot_id]) (404),
  # reset_bot_key, redirect_to account_bots_url.
  def update
    found = active_bot_id(id: params[:bot_id])
    return not_found if found.nil?
    reset_bot_token(id: params[:bot_id])
    redirect("/account/bots")
  end
end
