fragment do
  # Rails' health controller (rails/health#show): a page that is green.
  get "/up", description: "Health check", skip: [:authenticate] do
    html("<!DOCTYPE html><html><body style=\"background-color: green\"></body></html>")
  end
end
