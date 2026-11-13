model :Search, table: :searches do
  # app/models/search.rb
  belongs_to :user, model: :User

  scope :ordered, -> { order(updated_at: :desc) }

  # Search#ordered: the user's recent searches, newest first (searches_controller.rb index, Current.user.searches.ordered).
  record :RecentSearch do
    field :query, :string
  end

  query :recent_searches, args: { user_id: :i64 }, returns: list(:RecentSearch) do
    where(user_id: arg(:user_id)).order(updated_at: :desc, id: :desc).select(:query)
  end

  # Search.record(query): find_or_create_by(query:).touch, then after_create trim_recent_searches keeps the 10 newest.
  execute :touch_search, args: { user_id: :i64, query: :string } do
    where(user_id: arg(:user_id), query: arg(:query)).touch
  end

  execute :create_search, args: { user_id: :i64, query: :string }, sql: <<~SQL
    INSERT INTO searches (user_id, query, created_at, updated_at)
    SELECT :user_id, :query, strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM searches WHERE user_id = :user_id AND query = :query)
  SQL

  execute :trim_searches, args: { user_id: :i64 } do
    where(user_id: arg(:user_id)).where_not(id: Search.where(user_id: arg(:user_id)).order(updated_at: :desc, id: :desc).limit(10).select(:id)).delete
  end

  execute :clear_searches, args: { user_id: :i64 } do
    where(user_id: arg(:user_id)).delete
  end

  # User#deactivate's searches (see deactivate_user_memberships).
  execute :deactivate_user_searches, args: { id: :i64 } do
    where(user_id: arg(:id)).delete
  end
end
