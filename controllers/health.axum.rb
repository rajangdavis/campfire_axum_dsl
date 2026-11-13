controller do
  # Rails' health controller (rails/health#show): a page that is green.
  def show
    html("<!DOCTYPE html><html><body style=\"background-color: green\"></body></html>")
  end
end
