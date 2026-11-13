model :Webhook, table: :webhooks do
  # app/models/webhook.rb
  belongs_to :user, model: :User

  # BotsController: whether the bot has a webhook.
  query :webhook_count, args: { user_id: :i64 }, returns: :i64 do
    where(user_id: arg(:user_id)).count
  end

  # `user.create_webhook!(url:)`, and update_webhook_url!'s `webhook&.update!(url:) || create_webhook!(url:)`.
  execute :create_webhook, args: { user_id: :i64, url: :string } do
    insert(url: arg(:url), user_id: arg(:user_id))
  end

  # `webhook&.update!(url:)`: has_one, a user has one webhook; updated_at moves only when the URL changed.
  execute :update_webhook, args: { user_id: :i64, url: :string } do
    where(user_id: arg(:user_id)).update(url: arg(:url))
  end

  # `webhook&.destroy`.
  execute :delete_webhook, args: { user_id: :i64 } do
    where(user_id: arg(:user_id)).delete
  end
end
