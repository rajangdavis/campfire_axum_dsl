fragment do
  # ApplicationController's BlockBannedRequests (app/controllers/concerns/block_banned_requests.rb:5-17): a
  # before_action on every controller that skips get?/head? and answers `head :too_many_requests` when
  # Ban.banned?(request.remote_ip) — 429 with an empty text/html body. campfire.axum.rb includes this before
  # :authenticate so it runs inside it, as Rails' require_authentication then reject_banned_ip order does: an
  # unauthenticated non-GET to a protected path still redirects, while POST /session (which skips authentication)
  # is checked. No route skips it, and the method check covers the static and serve_file GET/HEAD routes.
  # One guard rather than an early `return "continue"`: `&&` short-circuits, so the ban query never runs for a
  # GET or HEAD, and the body's last expression is the "continue" sentinel the filter compiler understands.
  before :reject_banned_ip do
    return text("", status: 429, content_type: "text/html") if request_method != "GET" && request_method != "HEAD" && banned_ip(ip: request_ip) > 0
    "continue"
  end
end
