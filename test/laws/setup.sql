-- What the laws sign in as: a session per role, on the seed's users (1 David, administrator; 2 Jason, member).
INSERT INTO sessions (user_id, token, ip_address, user_agent, created_at, updated_at, last_active_at) VALUES
  (1, 'law-administrator-token', '127.0.0.1', 'laws', '2025-01-01 08:00:00.000', '2025-01-01 08:00:00.000', '2025-01-01 08:00:00.000'),
  (2, 'law-member-token', '127.0.0.1', 'laws', '2025-01-01 08:00:00.000', '2025-01-01 08:00:00.000', '2025-01-01 08:00:00.000');

