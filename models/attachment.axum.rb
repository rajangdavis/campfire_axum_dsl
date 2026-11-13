model :Attachment, table: :active_storage_attachments do
  # ActiveStorage::Attachment. An attachment names its record by type, id and name; the newest one answers when there
  # are several (the app attaches one logo and one avatar, so there is one).
  belongs_to :blob, model: :Blob

  execute :detach_variant_images, args: { blob_id: :i64 } do
    where(record_type: "ActiveStorage::VariantRecord", record_id: VariantRecord.where(blob_id: arg(:blob_id)).select(:id)).delete
  end

  # The logo's blob, read before the deletes (Accounts::LogosController#destroy and the logo replacement).
  query :account_logo_blob_id, args: {}, returns: :i64? do
    where(record_type: "Account", name: "logo").order(id: :desc).pick(:blob_id)
  end

  # Whether the account has a logo attached (account_logo_class, models/account.axum.rb).
  query :account_logo_attached, args: {}, returns: :bool do
    where(record_type: "Account", name: "logo").exists
  end

  # The user's avatar blob, read before `avatar.destroy` purges it.
  query :user_avatar_blob_id, args: { user_id: :i64 }, returns: :i64? do
    where(record_type: "User", record_id: arg(:user_id), name: "avatar").order(id: :desc).pick(:blob_id)
  end

  query :logo_source, args: {}, returns: :LogoSource? do
    joins(:blob).where(record_type: "Account", name: "logo").order(id: :desc)
      .select(key: col(:blob, :key), filename: col(:blob, :filename), content_type: col(:blob, :content_type))
  end

  query :avatar_source, args: { user_id: :i64 }, returns: :AvatarSource? do
    joins(:blob).where(record_type: "User", record_id: arg(:user_id), name: "avatar").order(id: :desc)
      .select(key: col(:blob, :key), filename: col(:blob, :filename), content_type: col(:blob, :content_type))
  end

  execute :detach_account_logo, args: {} do
    where(record_type: "Account", name: "logo").delete
  end

  # The user's avatar attachment statements (attach_user_avatar, detach_user_avatar ...) are derived by `has_one_attached :avatar`
  # in models/user.axum.rb; `attach(:avatar, ...)` runs them and `detach_user_avatar` is `Current.user.avatar.destroy`'s first step.

  # has_one_attached :attachment (Message::Attachment): the attachment row tying a blob (models/blob.axum.rb insert_blob)
  # to the message by the blob's key (the caller runs it only when the message has a file).
  execute :attach_message_file, args: { message_id: :i64, key: :string } do
    insert_from(Blob.where(key: arg(:key)), name: "attachment", record_type: "Message", record_id: arg(:message_id), blob_id: :id)
  end

  # `logo` assigned: has_one_attached replaces the attachment (the old blob and its variants are purged, which Rails
  # does in a later job) and the attachment's touch moves updated_at, so the logo's `?v=`. The new logo has no
  # variant until one is made: Rails resizes it with libvips on the first GET /account/logo, which the port cannot
  # (GAPS), so that answer stays the stock icon.
  execute :attach_account_logo, args: { key: :string } do
    insert_from(Blob.where(key: arg(:key)), name: "logo", record_type: "Account", record_id: expr(:sole_account_id), blob_id: :id)
  end

  # The blobs of a set of messages' attachments: one message, or every message of one person.
  query :message_blob_ids, args: { message_id: :i64 }, returns: :string do
    where(record_type: "Message", record_id: arg(:message_id)).pick(coalesce(group_concat(:blob_id), ""))
  end

  query :creator_message_blob_ids, args: { user_id: :i64 }, returns: :string do
    where(record_type: "Message", record_id: Message.where(creator_id: arg(:user_id)).select(:id)).pick(coalesce(group_concat(:blob_id), ""))
  end

  # The logo's blob and its variants' blobs, read before the deletes: the attachments that name them go first. A variant
  # record's id names at most one attachment row per attachment, so IN keeps exactly what the raw JOIN returned.
  query :variant_blob_ids, args: { blob_id: :i64 }, returns: :string do
    where(record_type: "ActiveStorage::VariantRecord", record_id: VariantRecord.where(blob_id: arg(:blob_id)).select(:id)).pick(coalesce(group_concat(:blob_id), ""))
  end

  # ActiveStorage::Blob#purge: the attachments that hang off the blobs `ids` names (comma-separated), a blob's variant
  # records' image attachments and the attachments whose record is the blob itself (its preview_image).
  execute :purge_blob_dependents, args: { ids: :string } do
    where(record_type: "ActiveStorage::VariantRecord", record_id: VariantRecord.where(blob_id: in_ids(arg(:ids))).select(:id))
      .or(where(record_type: "ActiveStorage::Blob", record_id: in_ids(arg(:ids)))).delete
  end
end
