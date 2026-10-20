-- A small seed for test/e2e_campfire.sh. Load db/migrate/001_schema.sql first (the script does), then this file:
--   sqlite3 campfire.sqlite3 < db/migrate/001_schema.sql && sqlite3 campfire.sqlite3 < test/seed.sql
--
-- Everyone's password is "campfire-test-pw". Every digest below is the same bcrypt hash of it ($2b$, cost 4, made with
-- the bcryptjs package and checked with its compareSync); cost 4 keeps the login quick, and the server's Bcrypt.verify
-- reads any cost. Messages 1..90 are in room 1, one minute apart, so the 60th message is id 60.
--
--   users:  1 david (administrator), 2 jason, 3 rita
--   rooms:  1 Watercooler (open; david, jason; 90 messages)
--           2 Sales & Support (open; david, jason, rita; 5 messages; the & is escaped in the sidebar)
--           3 Skunkworks (open; jason, rita ONLY; 4 messages, two say "coffee": search must not return them)
--           4 a direct room (david, jason; 2 messages)
--           5 Quiet Corner (open; david's membership is invisible, rita's is not; 1 message)

INSERT INTO users (id, name, email_address, password_digest, role, status, created_at, updated_at) VALUES
  (1, 'David Heinemeier', 'david@37signals.com', '$2b$04$DIGmu3C6b/joUFWxUNJ7qexx4i.4V69Hj.05jHgHMy5Y7UcWgFnkO', 1, 0, '2025-01-01 08:00:00.000', '2025-01-01 08:00:00.000'),
  (2, 'Jason Fried',      'jason@37signals.com', '$2b$04$DIGmu3C6b/joUFWxUNJ7qexx4i.4V69Hj.05jHgHMy5Y7UcWgFnkO', 0, 0, '2025-01-01 08:00:00.000', '2025-01-01 08:00:00.000'),
  (3, 'Rita Lopez',       'rita@37signals.com',  '$2b$04$DIGmu3C6b/joUFWxUNJ7qexx4i.4V69Hj.05jHgHMy5Y7UcWgFnkO', 0, 0, '2025-01-01 08:00:00.000', '2025-01-01 08:00:00.000');

INSERT INTO accounts (id, name, join_code, singleton_guard, created_at, updated_at)
  VALUES (1, 'Campfire Test', 'abcd-1234', 0, '2025-01-01 08:00:00.000', '2025-01-01 08:00:00.000');

-- Jason's processed :square avatar. The source blob is the user's avatar attachment; the variant record's
-- `image` attachment is the processed blob the controller serves. The e2e writes the variant bytes under
-- <ACTIVE_STORAGE_PATH>/ja/so/jasonavatarvariant (Active Storage's key sharding).
INSERT INTO active_storage_blobs (id, key, filename, content_type, metadata, service_name, byte_size, checksum, created_at) VALUES
  (1, 'jasonavatarsource', 'moon.jpg', 'image/jpeg', '{}', 'local', 1234, NULL, '2025-01-01 08:00:00.000'),
  (2, 'jasonavatarvariant', 'moon.webp', 'image/webp', '{}', 'local', 1234, NULL, '2025-01-01 08:00:00.000');

INSERT INTO active_storage_attachments (id, blob_id, record_type, record_id, name, created_at) VALUES
  (1, 1, 'User', 2, 'avatar', '2025-01-01 08:00:00.000'),
  (2, 2, 'ActiveStorage::VariantRecord', 1, 'image', '2025-01-01 08:00:00.000');

INSERT INTO active_storage_variant_records (id, blob_id, variation_digest)
  VALUES (1, 1, 'campfire-test-square');

INSERT INTO rooms (id, name, type, creator_id, created_at, updated_at) VALUES
  (1, 'Watercooler',     'Rooms::Open',   1, '2025-01-01 08:30:00.000', '2025-01-01 08:30:00.000'),
  (2, 'Sales & Support', 'Rooms::Open',   1, '2025-01-01 08:31:00.000', '2025-01-01 08:31:00.000'),
  (3, 'Skunkworks',      'Rooms::Open',   2, '2025-01-01 08:32:00.000', '2025-01-01 08:32:00.000'),
  (4, NULL,              'Rooms::Direct', 1, '2025-01-01 08:33:00.000', '2025-01-01 08:33:00.000'),
  (5, 'Quiet Corner',    'Rooms::Open',   3, '2025-01-01 08:34:00.000', '2025-01-01 08:34:00.000');

INSERT INTO memberships (room_id, user_id, involvement, created_at, updated_at) VALUES
  (1, 1, 'everything', '2025-01-01 08:30:00.000', '2025-01-01 08:30:00.000'),
  (1, 2, 'mentions',   '2025-01-01 08:30:00.000', '2025-01-01 08:30:00.000'),
  (2, 1, 'mentions',   '2025-01-01 08:31:00.000', '2025-01-01 08:31:00.000'),
  (2, 2, 'mentions',   '2025-01-01 08:31:00.000', '2025-01-01 08:31:00.000'),
  (2, 3, 'mentions',   '2025-01-01 08:31:00.000', '2025-01-01 08:31:00.000'),
  (3, 2, 'mentions',   '2025-01-01 08:32:00.000', '2025-01-01 08:32:00.000'),
  (3, 3, 'mentions',   '2025-01-01 08:32:00.000', '2025-01-01 08:32:00.000'),
  (4, 1, 'everything', '2025-01-01 08:33:00.000', '2025-01-01 08:33:00.000'),
  (4, 2, 'everything', '2025-01-01 08:33:00.000', '2025-01-01 08:33:00.000'),
  (5, 1, 'invisible',  '2025-01-01 08:34:00.000', '2025-01-01 08:34:00.000'),
  (5, 3, 'mentions',   '2025-01-01 08:34:00.000', '2025-01-01 08:34:00.000');

-- Room 1: messages 1..90, a minute apart, written by david (odd) and jason (even). Every 10th mentions coffee, every
-- 9th (not a 10th) has an ampersand, which the room page must show escaped.
CREATE TEMP TABLE seed_text AS
  WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 90)
  SELECT i,
         CASE WHEN i % 10 = 0 THEN 'Who wants coffee? Round ' || i
              WHEN i % 9 = 0 THEN 'Tom & Jerry meet again ' || i
              ELSE 'Plain chatter number ' || i END AS plain
  FROM n;

INSERT INTO messages (id, client_message_id, room_id, creator_id, created_at, updated_at)
  SELECT i, 'client-' || i, 1, CASE WHEN i % 2 = 1 THEN 1 ELSE 2 END,
         strftime('%Y-%m-%d %H:%M:%f', '2025-01-01 09:00:00', '+' || i || ' minutes'),
         strftime('%Y-%m-%d %H:%M:%f', '2025-01-01 09:00:00', '+' || i || ' minutes')
  FROM seed_text;

INSERT INTO action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at)
  SELECT 'Message', i, 'body', '<div class="trix-content">' || plain || '</div>', '2025-01-01 09:00:00.000', '2025-01-01 09:00:00.000'
  FROM seed_text;

INSERT INTO message_search_index (rowid, body) SELECT i, plain FROM seed_text;

DROP TABLE seed_text;

-- The other rooms: ids from 101, on 2 January, so created_at order and id order agree.
CREATE TEMP TABLE seed_more (id INTEGER, room_id INTEGER, creator_id INTEGER, at TEXT, plain TEXT);
INSERT INTO seed_more VALUES
  (101, 2, 1, '2025-01-02 09:01:00.000', 'Support queue is empty'),
  (102, 2, 3, '2025-01-02 09:02:00.000', 'Fresh coffee in the kitchen'),
  (103, 2, 2, '2025-01-02 09:03:00.000', 'Invoice 42 sent'),
  (104, 2, 1, '2025-01-02 09:04:00.000', 'Renewals due Friday'),
  (105, 2, 3, '2025-01-02 09:05:00.000', 'Closing the ticket'),
  (111, 3, 2, '2025-01-02 10:01:00.000', 'Secret coffee roadmap'),
  (112, 3, 3, '2025-01-02 10:02:00.000', 'Skunkworks only: launch plan'),
  (113, 3, 2, '2025-01-02 10:03:00.000', 'More coffee for the skunks'),
  (114, 3, 3, '2025-01-02 10:04:00.000', 'Nothing to see here'),
  (121, 4, 2, '2025-01-02 11:01:00.000', 'Got a minute?'),
  (122, 4, 1, '2025-01-02 11:02:00.000', 'Sure, calling now'),
  (131, 5, 3, '2025-01-02 12:01:00.000', 'Quiet in here');

INSERT INTO messages (id, client_message_id, room_id, creator_id, created_at, updated_at)
  SELECT id, 'client-' || id, room_id, creator_id, at, at FROM seed_more;
INSERT INTO action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at)
  SELECT 'Message', id, 'body', '<div class="trix-content">' || plain || '</div>', at, at FROM seed_more;
INSERT INTO message_search_index (rowid, body) SELECT id, plain FROM seed_more;
DROP TABLE seed_more;
