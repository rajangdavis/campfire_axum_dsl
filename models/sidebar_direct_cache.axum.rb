model :SidebarDirectCache, table: :axum_dsl_sidebar_direct_cache do
  # `cache membership` around each direct entry (db/migrate/002_sidebar_direct_cache.sql): the first render under a
  # membership's id and updated_at records its unread state, and later renders under the same key show that one.
  execute :cache_sidebar_direct, args: { user_id: :i64 } do
    insert_from(Membership.joins(:room).where(user_id: arg(:user_id), room: { type: "Rooms::Direct" }).where_not(involvement: "invisible"),
                membership_id: :id, membership_updated_at: :updated_at, unread: expr(:unread_marker), on_duplicate: :skip)
  end
end
