fragment do
  # --- params -------------------------------------------------------------------------------------------------------

  params :Login do
    field :email_address, :string, in: :form
    field :password, :string, in: :form
  end

  params :RoomPath do
    field :id, :i64, in: :path
  end

  params :PageParams do
    field :id, :i64, in: :path
    field :before, :i64, in: :query
  end

  params :SearchParams do
    field :q, :string, in: :query, optional: true
  end

  # Users::AvatarsController#show: the web path segment is a Rails signed_id token, not a numeric user id.
  params :AvatarPath do
    field :token, :string, in: :path
  end

  # MessagesController#create: the room in the path, the submitted message in the form. Rails' form posts the
  # bracketed wire names (`message[body]`), declared with `name:`; the body still reads `params[:body]` (GAPS.md 13).
  params :NewMessage do
    field :id, :i64, in: :path
    field :body, :string, in: :form, name: "message[body]"
    field :client_message_id, :string, in: :form, name: "message[client_message_id]", optional: true
  end
end
