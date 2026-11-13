model "Push::Subscription", table: :push_subscriptions do
  # app/models/push/subscription.rb
  belongs_to :user, model: :User

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

  # Push::Subscription's validations, as a 1 or a 0: a present endpoint that parses as an https URL on port 443 whose host
  # is one of PERMITTED_ENDPOINT_HOSTS or a subdomain of one. Rails also resolves the host and refuses a private or
  # unresolvable address (RestrictedHTTP::PrivateNetworkGuard); the port does not look the host up.
  query :push_endpoint_valid, args: { endpoint: :string }, returns: :i64, sql: <<~SQL
    WITH r AS (
      SELECT CASE WHEN lower(substr(:endpoint, 1, 8)) = 'https://' THEN substr(:endpoint, 9) END AS rest
    ), a AS (
      SELECT CASE WHEN rest IS NULL THEN NULL
                  ELSE substr(rest, 1, min(CASE WHEN instr(rest, '/') > 0 THEN instr(rest, '/') - 1 ELSE length(rest) END,
                                           CASE WHEN instr(rest, '?') > 0 THEN instr(rest, '?') - 1 ELSE length(rest) END,
                                           CASE WHEN instr(rest, '#') > 0 THEN instr(rest, '#') - 1 ELSE length(rest) END)) END AS auth
      FROM r
    ), h AS (
      SELECT lower(CASE WHEN instr(auth, ':') > 0 THEN substr(auth, 1, instr(auth, ':') - 1) ELSE auth END) AS host,
             CASE WHEN instr(auth, ':') > 0 THEN substr(auth, instr(auth, ':') + 1) ELSE '' END AS port
      FROM a WHERE auth IS NOT NULL
    )
    SELECT COUNT(*) FROM h
    WHERE :endpoint <> '' AND host <> '' AND port IN ('', '443')
      AND EXISTS (SELECT 1 FROM (SELECT 'jmt17.google.com' AS p UNION ALL SELECT 'fcm.googleapis.com'
                                 UNION ALL SELECT 'updates.push.services.mozilla.com' UNION ALL SELECT 'web.push.apple.com'
                                 UNION ALL SELECT 'notify.windows.com')
                  WHERE host = p OR substr(host, -length(p) - 1) = '.' || p)
  SQL

  # `@push_subscriptions.find_by(endpoint:, p256dh_key:, auth_key:)`: the person's own, the first in id order.
  record :PushSubscriptionMatch do
    field :id, :i64
    field :endpoint, :string
  end

  query :own_push_subscription, args: { user_id: :i64, endpoint: :string, p256dh_key: :string, auth_key: :string }, returns: :PushSubscriptionMatch? do
    where(user_id: arg(:user_id), endpoint: arg(:endpoint), p256dh_key: arg(:p256dh_key), auth_key: arg(:auth_key)).order(:id).select(:id, endpoint: coalesce(:endpoint, ""))
  end

  execute :touch_push_subscription, args: { id: :i64 } do
    where(id: arg(:id)).touch
  end

  execute :create_push_subscription, args: { user_id: :i64, endpoint: :string, p256dh_key: :string, auth_key: :string, user_agent: :string } do
    insert(auth_key: arg(:auth_key), endpoint: arg(:endpoint), p256dh_key: arg(:p256dh_key), user_agent: arg(:user_agent), user_id: arg(:user_id))
  end

  execute :delete_own_push_subscription, args: { user_id: :i64, id: :i64 } do
    where(user_id: arg(:user_id), id: arg(:id)).delete
  end

  query :own_push_subscription_id, args: { user_id: :i64, id: :i64 }, returns: :i64? do
    where(user_id: arg(:user_id), id: arg(:id)).pick(:id)
  end

  execute :delete_push_subscription_by_endpoint, args: { endpoint: :string, user_id: :i64 } do
    where(endpoint: arg(:endpoint), user_id: arg(:user_id)).delete
  end

  # The pool's invalid-subscription handler: `Push::Subscription.find_by(id:)&.destroy`.
  execute :delete_push_subscription_by_id, args: { id: :i64 } do
    where(id: arg(:id)).delete
  end

  # User#deactivate's push subscriptions (see deactivate_user_memberships).
  execute :deactivate_user_push_subscriptions, args: { id: :i64 } do
    where(user_id: arg(:id)).delete
  end
end
