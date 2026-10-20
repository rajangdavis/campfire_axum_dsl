fragment do
  execute :start_session, args: { token: :string, user_id: :i64, ip: :string, agent: :string }, sql: <<~SQL
    INSERT INTO sessions (user_id, token, user_agent, ip_address, last_active_at, created_at, updated_at)
    VALUES (:user_id, :token, :agent, :ip, strftime('%Y-%m-%d %H:%M:%f', 'now'),
            strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now'))
  SQL

  execute :end_session, args: { token: :string }, sql: "DELETE FROM sessions WHERE token = :token"
end
