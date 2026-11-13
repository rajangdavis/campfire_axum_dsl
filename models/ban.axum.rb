model :Ban, table: :bans do
  # app/models/ban.rb
  belongs_to :user, model: :User

  # Ban.banned?(request.remote_ip) (app/models/ban.rb:8-10): `exists?(ip_address: ip_address)`, a COUNT over the
  # plain index_bans_on_ip_address. BlockBannedRequests calls it for every non-GET/HEAD request.
  query :banned_ip, args: { ip: :string }, returns: :i64 do
    where(ip_address: arg(:ip)).count
  end

  # User::Bannable#create_bans_from_sessions: one Ban per distinct non-blank session IP. Ban's ip_address_is_public
  # refuses a loopback, private or link-local address (RecordInvalid, which rolls the ban back and answers 422).
  query :private_session_ip_count, args: { user_id: :i64 }, returns: :i64, sql: <<~SQL
    SELECT COUNT(*) FROM (SELECT DISTINCT ip_address AS ip FROM sessions WHERE user_id = :user_id AND COALESCE(ip_address, '') <> '')
    WHERE ip LIKE '10.%' OR ip LIKE '127.%' OR ip LIKE '192.168.%' OR ip LIKE '169.254.%' OR ip = '::1'
       OR (ip LIKE '172.%' AND CAST(substr(ip, 5, instr(substr(ip, 5), '.') - 1) AS INTEGER) BETWEEN 16 AND 31)
       OR lower(ip) LIKE 'fc%' OR lower(ip) LIKE 'fd%' OR lower(ip) LIKE 'fe80:%'
  SQL

  execute :ban_session_ips, args: { user_id: :i64 } do
    insert_from(Session.where(user_id: arg(:user_id)).where_not(ip_address: "").distinct.order(:id), user_id: arg(:user_id), ip_address: :ip_address)
  end

  execute :delete_user_bans, args: { user_id: :i64 } do
    where(user_id: arg(:user_id)).delete
  end
end
