model :Blob, table: :active_storage_blobs do
  # ActiveStorage::Blob. The queries that read a blob row for itself.

  # Time#httpdate (the blob's Last-Modified): "Sun, 06 Nov 1994 08:49:37 GMT", from a stored UTC timestamp.
  expr :http_date, type: :string,
       sql: "CASE strftime('%w', {t}.created_at) WHEN '0' THEN 'Sun' WHEN '1' THEN 'Mon' WHEN '2' THEN 'Tue' WHEN '3' THEN 'Wed' WHEN '4' THEN 'Thu' WHEN '5' THEN 'Fri' ELSE 'Sat' END || strftime(', %d ', {t}.created_at) || CASE strftime('%m', {t}.created_at) WHEN '01' THEN 'Jan' WHEN '02' THEN 'Feb' WHEN '03' THEN 'Mar' WHEN '04' THEN 'Apr' WHEN '05' THEN 'May' WHEN '06' THEN 'Jun' WHEN '07' THEN 'Jul' WHEN '08' THEN 'Aug' WHEN '09' THEN 'Sep' WHEN '10' THEN 'Oct' WHEN '11' THEN 'Nov' ELSE 'Dec' END || strftime(' %Y %H:%M:%S GMT', {t}.created_at)"
  # Account.first.id: the id of the single account row (the accounts table holds one, singleton_guard). It is a Blob expr because
  # `insert_from(Blob.where(...), record_id: expr(:sole_account_id))` (models/attachment.axum.rb) reads its values in the Blob frame.
  expr :sole_account_id, type: :i64, sql: "(SELECT id FROM accounts LIMIT 1)"

  # The blob a signed id names: where its file is and what it is called.
  query :blob_file, args: { id: :i64 }, returns: :BlobFile? do
    where(id: arg(:id)).select(:key, :filename, :content_type)
  end

  # The blob a disk key names; Last-Modified is the file's, approximated by the blob's creation time as an HTTP date.
  query :disk_blob, args: { key: :string }, returns: :DiskBlob? do
    where(key: arg(:key)).select(content_type: coalesce(:content_type, ""), filename: :filename, last_modified: expr(:http_date))
  end

  # ActiveStorage::Blob.create_and_upload!: the row of a file `upload.store(root)` has written, found again by its key. A
  # route with no file does not call it. The caller passes the metadata: a message attachment the upload's analyzed
  # `metadata` (Rails renders the new message with its width and height), an avatar `{"identified":true}` (analysis is a
  # later job there).
  execute :insert_blob, args: { key: :string, filename: :string, content_type: :string, metadata: :string, byte_size: :i64, checksum: :string } do
    insert(key: arg(:key), filename: arg(:filename), content_type: arg(:content_type), metadata: arg(:metadata), service_name: "local", byte_size: arg(:byte_size), checksum: arg(:checksum))
  end

  execute :delete_blobs, args: { ids: :string } do
    where(id: in_ids(arg(:ids))).delete
  end

  # The blobs themselves, once nothing names them (a blob still attached elsewhere is kept, as purge would fail there).
  execute :purge_blobs, args: { ids: :string } do
    where(id: in_ids(arg(:ids))).where_not(id: Attachment.select(:blob_id)).delete
  end

  execute :delete_blob, args: { id: :i64 } do
    where(id: arg(:id)).delete
  end
end
