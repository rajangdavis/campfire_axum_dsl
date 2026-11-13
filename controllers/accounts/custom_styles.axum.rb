# Accounts::CustomStylesController: the account's custom CSS.
controller do

  layout_locals do
    signed_in = true
    user_id = current_user.id
    user_name = current_user.name
  end

  before :ensure_can_administer

  # Accounts::CustomStylesController#edit: the account's custom CSS.
  def edit
    flash = take_flash
    page = account_page || raise("the account was not read back")
    flags = account_flags
    account_settings_row = account_settings || raise("the account settings were not read back")
    body_class = account_body_class(flags)
    render :account_custom_styles, locals: { title: "Custom styles", logo_version: page.logo_version, flash_on: flash.on, flash_alert: flash.alert, flash_text: flash.text, custom_styles: account_settings_row.custom_styles, custom_styles_action: "#{request_base_url}/account/custom_styles" }
  end

  params :CustomStylesUpdate do
    field :custom_styles, :string, in: :form, name: "account[custom_styles]"
  end

  # Accounts::CustomStylesController#update: ensure_can_administer (`head :forbidden`), update!, then
  # `redirect_to edit_account_custom_styles_url, notice: "✓"`, the notice carried as GET /account/edit carries it.
  def update
    update_custom_styles(css: params[:custom_styles])
    redirect("/account/custom_styles/edit", notice: :notice_saved)
  end
end
