# Accounts::JoinCodesController: a new join code.
controller do
  before :ensure_can_administer

  # Accounts::JoinCodesController#create: ensure_can_administer, reset_join_code, redirect_to edit_account_url.
  def create
    reset_join_code
    redirect("/account/edit")
  end
end
