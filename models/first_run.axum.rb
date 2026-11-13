model do
  # FirstRun.create!: Account.create!(name: "Campfire"). Account::Joinable's before_create sets the join code,
  # SecureRandom.alphanumeric(12) as three groups of four joined by "-"; each character is drawn from the same
  # 62-letter alphabet here. has_json :settings writes its default; singleton_guard is the column's default, 0.
  execute :create_first_account, args: {}, sql: <<~SQL
    WITH RECURSIVE pick(n, code) AS (
      SELECT 0, ''
      UNION ALL
      SELECT n + 1, code || CASE WHEN n IN (4, 8) THEN '-' ELSE '' END ||
             substr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789', (abs(random()) % 62) + 1, 1)
      FROM pick WHERE n < 12
    )
    INSERT INTO accounts (name, join_code, settings, singleton_guard, created_at, updated_at)
    SELECT 'Campfire', code, '{"restrict_room_creation_to_administrators":false}', 0,
           strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now')
    FROM pick WHERE n = 12
  SQL

  # FirstRun.create!(user_params) and start_new_session_for(user): the account, its administrator (with an avatar when
  # one came), the "All Talk" open room with the administrator in it, and the session, in one transaction. The rows
  # the session insert changed: 1 when the person is signed in.
  def create_first_run(name, email, password, avatar, token, ip, agent)
    digest = Bcrypt.hash(password)
    stored = avatar&.store_file(setting(:storage))
    transaction do
      create_first_account
      id = create_administrator(name: name, email: email, digest: digest)
      room_id = create_room(name: "All Talk", creator_id: id, room_type: "Rooms::Open")
      grant_room_member(room_id: room_id, user_id: id)
      attach(:avatar, id, stored, fresh: true)
      start_session(token: token, user_id: id, ip: ip, agent: agent)
    end
  end
end
