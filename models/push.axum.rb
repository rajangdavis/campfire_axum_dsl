model do
  # Room::MessagePusher: who a new message's Web Push goes to. relevant_subscriptions is every push subscription of a
  # member of the room whose membership is visible (not `invisible`) and disconnected (no connection in the last
  # CONNECTION_TTL, 60 seconds), the message's creator excepted; of those, the members involved in `everything`, then
  # the ones involved in `mentions` whom the body mentions (Message#mentionees: room members among the body's User
  # attachables). Each notification's badge is its user's unread memberships (`user.memberships.unread.count`).
  record :PushTarget do
    field :id, :i64
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string
    field :badge, :i64
  end

  query :push_targets, args: { room_id: :i64, creator_id: :i64, body: :string }, returns: list(:PushTarget), sql: <<~SQL
    WITH relevant AS (
      SELECT s.id AS id, COALESCE(s.endpoint, '') AS endpoint, COALESCE(s.p256dh_key, '') AS p256dh,
             COALESCE(s.auth_key, '') AS auth, s.user_id AS user_id, m.involvement AS involvement
      FROM push_subscriptions s
      JOIN memberships m ON m.user_id = s.user_id AND m.room_id = :room_id
      WHERE m.involvement <> 'invisible' AND m.user_id <> :creator_id
        AND (m.connected_at IS NULL OR m.connected_at < strftime('%Y-%m-%d %H:%M:%f', 'now', '-60 seconds'))
    ), chosen AS (
      SELECT id, endpoint, p256dh, auth, user_id, 0 AS pass FROM relevant WHERE involvement = 'everything'
      UNION ALL
      SELECT id, endpoint, p256dh, auth, user_id, 1 AS pass FROM relevant
      WHERE involvement = 'mentions' AND user_id IN (SELECT value FROM json_each(action_text_attachable_ids(:body, 'User')))
    )
    SELECT c.id, c.endpoint, c.p256dh, c.auth,
           (SELECT COUNT(*) FROM memberships u WHERE u.user_id = c.user_id AND u.unread_at IS NOT NULL) AS badge
    FROM chosen c ORDER BY c.pass, c.id
  SQL

  # MessagesController#deliver_webhooks_to_bots: `@room.direct? ? @room.users.active_bots : @message.mentionees.active_bots`,
  # the message's creator excepted, each bot that has a webhook (`deliver_webhook_later ... if webhook`), with its bot
  # key (Webhook#room_bot_messages_path) and its webhook's URL (has_one: the first).
  record :WebhookBot do
    field :id, :i64
    field :name, :string
    field :bot_key, :string
    field :url, :string
  end

  # The query (webhook_bots) is in models/user.axum.rb.
end
