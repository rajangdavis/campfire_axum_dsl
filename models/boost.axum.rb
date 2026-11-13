model :Boost, table: :boosts do
  # app/models/boost.rb
  belongs_to :message, model: :Message
  belongs_to :booster, model: :User
  include :Timestamps # created_iso_ms

  scope :ordered, -> { order(:created_at) }

  # message.boosts.ordered, each with its booster as avatar_tag draws them (record :BoostRow, models/message.axum.rb).
  query :message_boosts, args: { id: :i64 }, returns: list(:BoostRow) do
    joins(:booster).where(message_id: arg(:id))
      .select(:id, :booster_id, :content, booster_name: col(:booster, :name), booster_title: expr(:user_title, :booster),
              booster_version: expr(:updated_at_number, :booster))
      .order(:created_at, :id)
  end

  # The one boost messages/boosts/_boost draws for a broadcast.
  query :boost_row, args: { id: :i64 }, returns: :BoostRow? do
    joins(:booster).where(id: arg(:id))
      .select(:id, :booster_id, :content, booster_name: col(:booster, :name), booster_title: expr(:user_title, :booster),
              booster_version: expr(:updated_at_number, :booster))
  end

  # messages/boosts/_boost.json.jbuilder: the boost with its booster and its message's url parts (record :BotBoost, models/bot_api.axum.rb).
  query :bot_boost, args: { id: :i64 }, returns: :BotBoost? do
    joins(:message).left_joins(:booster).where(id: arg(:id))
      .select(id: :id, content: :content, created_at: expr(:created_iso_ms), booster_id: :booster_id,
              booster_name: coalesce(col(:booster, :name), ""), booster_role: coalesce(expr(:role_name, :booster), ""),
              avatar_version: coalesce(expr(:updated_at_number, :booster), ""), room_id: col(:message, :room_id), message_id: col(:message, :id))
  end

  # Messages::Boosts::ByBotsController#create: `@message.boosts.create!(content:)`, which touches the message.
  query :create_boost, args: { message_id: :i64, booster_id: :i64, content: :string }, returns: :i64 do
    insert(message_id: arg(:message_id), booster_id: arg(:booster_id), content: arg(:content), returning: :id)
  end
end
