# Accounts::LogosController: removing the account's logo.
controller do
  before :ensure_can_administer

  # Accounts::LogosController#destroy: ensure_can_administer, the logo's destroy (a no-op without one), redirect_to edit_account_url.
  def destroy
    logo = account_logo_blob_id
    return redirect("/account/edit") if logo.nil? # no logo: the destroy is a no-op
    purge_account_logo(logo)
    redirect("/account/edit")
  end
end
