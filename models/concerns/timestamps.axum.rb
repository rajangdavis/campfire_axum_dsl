concern :Timestamps do
  # app/models/concerns: the time stamps of a row, read as the pages and the bot API write them. A model with created_at and
  # updated_at columns says `include :Timestamps`; its relations then find these by name, and so does `expr(:updated_at_number, :creator)`
  # for the model that owns the joined table (here User, which includes it).

  # updated_at.to_fs(:number), the `?v=` of an avatar or logo URL (fresh_user_avatar_path): 20261112093000.
  expr :updated_at_number, type: :string, sql: "strftime('%Y%m%d%H%M%S', {t}.updated_at)"
  # MessageRow: a message's created_at and updated_at as epoch milliseconds, and created_at as ISO 8601 (the data attributes
  # Rails writes, and the `since` the polling endpoint compares with).
  expr :created_ms, type: :i64,
       sql: "CAST(strftime('%s', {t}.created_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', {t}.created_at), 4) AS INTEGER)"
  expr :updated_ms, type: :i64,
       sql: "CAST(strftime('%s', {t}.updated_at) AS INTEGER) * 1000 + CAST(substr(strftime('%f', {t}.updated_at), 4) AS INTEGER)"
  expr :created_iso, type: :string, sql: "strftime('%Y-%m-%dT%H:%M:%SZ', {t}.created_at)"
  # created_at.utc as the bot API's JSON writes it: ISO 8601 with three fractional digits, cut not rounded.
  expr :created_iso_ms, type: :string,
       sql: "strftime('%Y-%m-%dT%H:%M:%S', {t}.created_at) || '.' || CASE WHEN length({t}.created_at) >= 23 THEN substr({t}.created_at, 21, 3) ELSE '000' END || 'Z'"
end
