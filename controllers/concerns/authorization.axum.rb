# ApplicationController's Authorization and the account pages' shared steps, as top-level defs any route may call.
fragment do
  # The signed-in person's account flags (administrator, logo): what ensure_can_administer and the body class read.
  def account_flags
    current_flags
  end

  # Authorization#ensure_can_administer: `head :forbidden unless Current.user.can_administer?`.
  def ensure_can_administer
    flags = account_flags
    return head(403) unless flags.admin == 1
  end

  # The layout's body class on the account pages: "admin" for an administrator, "account-has-logo" when there is one.
  def account_body_class(flags)
    "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip
  end

  # ActiveRecord::RecordNotFound, rescued as Rails rescues it: the static 404 page.
  def not_found
    html(file_text(:page_404), status: 404, content_type: "text/html; charset=UTF-8")
  end
end
