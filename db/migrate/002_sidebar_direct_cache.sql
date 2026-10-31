-- Rails' users/sidebars/rooms/_direct.html.erb is `cache membership` (rendered `cached: true`, production
-- redis_cache_store): a direct room's sidebar entry is kept under the membership's cache key (id and updated_at).
-- Membership.connect clears unread_at with update_all, which leaves updated_at alone, so after a visit Rails still
-- serves the entry it cached while the room was unread. This table stands in for that fragment cache: the unread
-- state an entry was first drawn with, per membership id and updated_at (models/sidebar.axum.rb).
CREATE TABLE IF NOT EXISTS "axum_dsl_sidebar_direct_cache" (
  "membership_id" integer NOT NULL,
  "membership_updated_at" text NOT NULL,
  "unread" integer NOT NULL,
  PRIMARY KEY ("membership_id", "membership_updated_at")
);
