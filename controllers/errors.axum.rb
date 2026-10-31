fragment do
  # Rails' public/404.html, 422.html, 500.html and 502.html are serve_file routes (campfire.axum.rb); a missing
  # record (ActiveRecord::RecordNotFound in production) and an unknown path answer 404 with the same page.
  not_found do
    status 404
    html(file_text(:page_404))
  end
end
