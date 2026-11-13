# Laws over the account controllers (AccountsController and Accounts::*): who may reach them, and what an unknown
# record answers. They hold for the routes as written now and must keep holding through the controller refactor.
fragment do
  params :LawRecordId do
    field :id, :i64, min: 1, max: 2_000_000_000
  end

  law :bots_need_an_administrator do
    member = respond(:get, "/account/bots", headers: { "Cookie" => cookie_header(:session_token, "law-member-token") })
    admin = respond(:get, "/account/bots", headers: { "Cookie" => cookie_header(:session_token, "law-administrator-token") })
    member.status == 403 && admin.status == 200
  end

  # Accounts::BotsController's set_bot: User.active_bots.find raises RecordNotFound, a 404, for any id that is not
  # an active bot (the seed has none); a member is refused before the lookup.
  law :an_unknown_bot_is_not_found, forall: :LawRecordId, cases: 64 do |id|
    admin = respond(:get, "/account/bots/#{id}/edit", headers: { "Cookie" => cookie_header(:session_token, "law-administrator-token") })
    member = respond(:get, "/account/bots/#{id}/edit", headers: { "Cookie" => cookie_header(:session_token, "law-member-token") })
    admin.status == 404 && member.status == 403
  end

  # AccountsController's `before_action :ensure_can_administer, only: :update` and Accounts::UsersController's
  # `only: %i[update destroy]`: the settings page and the people stream are a member's too.
  law :members_see_the_settings_and_the_people do
    member = { "Cookie" => cookie_header(:session_token, "law-member-token") }
    stream = { "Cookie" => cookie_header(:session_token, "law-member-token"), "Accept" => "text/vnd.turbo-stream.html" }
    respond(:get, "/account/edit", headers: member).status == 200 &&
      respond(:get, "/account/users.turbo_stream", headers: stream).status == 200
  end

  # Every other account page is an administrator's (ensure_can_administer on the whole controller).
  law :administrator_pages_refuse_a_member do
    member = { "Cookie" => cookie_header(:session_token, "law-member-token") }
    admin = { "Cookie" => cookie_header(:session_token, "law-administrator-token") }
    %w[/account/bots /account/bots/new /account/custom_styles/edit].all? do |path|
      respond(:get, path, headers: member).status == 403 && respond(:get, path, headers: admin).status == 200
    end
  end

  # The writes refuse a member before they change anything, whatever the target.
  law :account_writes_refuse_a_member, forall: :LawRecordId, cases: 32 do |id|
    member = { "Cookie" => cookie_header(:session_token, "law-member-token") }
    [respond(:post, "/account/join_code", headers: member).status,
     respond(:delete, "/account/logo", headers: member).status,
     respond(:patch, "/account/custom_styles", body: "account%5Bcustom_styles%5D=x", headers: member).status,
     respond(:patch, "/account", body: "account%5Bname%5D=x", headers: member).status,
     respond(:patch, "/account/users/#{id}", body: "user%5Brole%5D=administrator", headers: member).status,
     respond(:delete, "/account/users/#{id}", headers: member).status,
     respond(:delete, "/account/bots/#{id}", headers: member).status,
     respond(:put, "/account/bots/#{id}/key", headers: member).status].all? { |status| status == 403 }
  end
end
