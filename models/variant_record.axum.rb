model :VariantRecord, table: :active_storage_variant_records do
  # ActiveStorage::VariantRecord. A blob's variants, deleted with the blob (the logo, an avatar, a destroyed message's file).
  execute :delete_variant_records, args: { blob_id: :i64 } do
    where(blob_id: arg(:blob_id)).delete
  end

  execute :purge_blob_variant_records, args: { ids: :string } do
    where(blob_id: in_ids(arg(:ids))).delete
  end

  # create_or_find_by!(variation_digest:): the record of the source blob, found by its key.
  execute :create_variant_record, args: { blob_key: :string, digest: :string } do
    insert_from(Blob.where(key: arg(:blob_key)), blob_id: :id, variation_digest: arg(:digest))
  end
end
