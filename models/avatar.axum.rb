fragment do
  # --- avatars (app/controllers/users/avatars_controller.rb, app/models/user/avatar.rb) ---------------------------

  # The processed :square variant's blob key. Rails' avatar_variant is `avatar.variant(:square).processed`; the
  # variant record's `image` attachment is the processed blob, and the source blob is the user's avatar.
  record :Avatar do
    field :key, :string
  end

  query :avatar_variant, args: { user_id: :i64 }, returns: :Avatar?, sql: <<~SQL
    SELECT variant_blobs.key AS key
    FROM active_storage_attachments AS avatars
    JOIN active_storage_variant_records AS variants ON variants.blob_id = avatars.blob_id
    JOIN active_storage_attachments AS images
      ON images.record_type = 'ActiveStorage::VariantRecord'
     AND images.record_id = variants.id
     AND images.name = 'image'
    JOIN active_storage_blobs AS variant_blobs ON variant_blobs.id = images.blob_id
    WHERE avatars.record_type = 'User' AND avatars.record_id = :user_id AND avatars.name = 'avatar'
    ORDER BY variants.id DESC LIMIT 1
  SQL
end
