fragment do
  # Ban.banned?(request.remote_ip) (app/models/ban.rb:8-10): `exists?(ip_address: ip_address)`, a COUNT over the
  # plain index_bans_on_ip_address. BlockBannedRequests calls it for every non-GET/HEAD request.
  query :banned_ip, args: { ip: :string }, returns: :i64, sql: <<~SQL
    SELECT COUNT(*) FROM bans WHERE ip_address = :ip
  SQL
end
