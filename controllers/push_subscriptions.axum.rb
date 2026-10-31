fragment do
  # Users::PushSubscriptionsController#index (users/push_subscriptions/index.html.erb): the signed-in user's Web Push
  # subscriptions, in id order. The row's browser, version and platform are `UserAgent.parse(user_agent)` as the
  # useragent gem answers them for the agents Campfire sees: the browser is the one platform.axum.rb's pwa_browser
  # names (an Edge/ or OPR/ suffix, then Chrome/CriOS, then WebKit's Safari, then Firefox), the version is that
  # product's token (Safari's is Version/), and the platform is the first entry of the header's comment, Windows for
  # any Windows NT entry.
  record :PushSubscriptionRow do
    field :id, :i64
    field :endpoint, :string
    field :browser, :string
    field :version, :string
    field :platform, :string
  end

  query :push_subscriptions_for, args: { user_id: :i64 }, returns: list(:PushSubscriptionRow), sql: <<~SQL
    WITH s AS (
      SELECT id, COALESCE(endpoint, '') AS endpoint, COALESCE(user_agent, '') AS ua
      FROM push_subscriptions WHERE user_id = :user_id
    ), b AS (
      SELECT id, endpoint, ua,
             CASE WHEN ua LIKE '%Edge/%' THEN 'Edge'
                  WHEN ua LIKE 'Opera%' OR ua LIKE '%OPR/%' THEN 'Opera'
                  WHEN instr(ua, 'Chrome/') > 0 OR instr(ua, 'CriOS/') > 0 THEN 'Chrome'
                  WHEN instr(ua, 'AppleWebKit') > 0 THEN 'Safari'
                  WHEN instr(ua, 'Firefox/') > 0 THEN 'Firefox'
                  ELSE '' END AS browser
      FROM s
    ), m AS (
      SELECT id, endpoint, ua, browser,
             CASE browser WHEN 'Edge' THEN 'Edge/' WHEN 'Opera' THEN 'OPR/' WHEN 'Safari' THEN 'Version/'
                          WHEN 'Firefox' THEN 'Firefox/'
                          WHEN 'Chrome' THEN CASE WHEN instr(ua, 'Chrome/') > 0 THEN 'Chrome/' ELSE 'CriOS/' END
                          ELSE '' END AS marker
      FROM b
    ), t AS (
      SELECT id, endpoint, ua, browser,
             CASE WHEN marker <> '' AND instr(ua, marker) > 0 THEN substr(ua, instr(ua, marker) + length(marker)) ELSE '' END AS tail,
             CASE WHEN instr(ua, '(') > 0 THEN substr(ua, instr(ua, '(') + 1) ELSE '' END AS comment
      FROM m
    ), p AS (
      SELECT id, endpoint, browser, tail,
             CASE WHEN instr(comment, ';') > 0 AND (instr(comment, ')') = 0 OR instr(comment, ';') < instr(comment, ')'))
                  THEN substr(comment, 1, instr(comment, ';') - 1)
                  WHEN instr(comment, ')') > 0 THEN substr(comment, 1, instr(comment, ')') - 1)
                  ELSE comment END AS entry
      FROM t
    )
    SELECT id, endpoint, browser,
           CASE WHEN instr(tail, ' ') > 0 THEN substr(tail, 1, instr(tail, ' ') - 1) ELSE tail END AS version,
           CASE WHEN entry LIKE 'Windows%' THEN 'Windows' ELSE entry END AS platform
    FROM p ORDER BY id
  SQL

  get "/users/me/push_subscriptions", description: "Your Web Push subscriptions" do
    user = current(:user)
    flags = body_flags(user_id: user.id) || raise("the user was not read back")
    subscriptions = push_subscriptions_for(user_id: user.id)
    back_room_id = last_form_room_id(user_id: user.id, saved: cookie(:last_room, signed: false).to_s.to_i) || 0
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}"
    render :push_subscriptions, locals: { title: "Push notification subscriptions", body_class: body_class, vapid_key: setting(:vapid_public_key), logo_version: account_logo_version || "", signed_in: true, user_id: user.id, user_name: user.name, flash_on: false, flash_alert: false, flash_text: "", back_room_id: back_room_id, subscriptions: subscriptions }
  end
end
