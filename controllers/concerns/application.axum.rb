# ApplicationController's shared view context: the values every page layout reads. A fragment of top-level
# `layout_locals` is the service's (docs/views.md, "Layout locals"): a render whose view reads one gets it
# without a `locals:` entry, and one that reads neither never runs the query or reads the setting.
fragment do
  layout_locals do
    account_css = account_custom_styles
    vapid_key = setting(:vapid_public_key)
    flash_on = false
    flash_alert = false
    flash_text = ""
  end
end
