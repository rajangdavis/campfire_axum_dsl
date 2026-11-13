fragment do
  # --- params -------------------------------------------------------------------------------------------------------

  params :Login do
    field :email_address, :string, in: :form
    field :password, :string, in: :form
  end

  # SessionsController#new: sessions/new.html.erb writes `value: params[:email_address]`, which UsersController#create's
  # duplicate-e-mail redirect supplies (`new_session_url(email_address:)`). A missing parameter is "".
  params :SessionNewParams do
    field :email_address, :string, in: :query, optional: true
  end

  params :RoomPath do
    field :id, :i64, in: :path
  end

  # RoomsController#show reached through routes.rb `get "@:message_id", as: :at_message`.
  params :RoomAtPath do
    field :id, :i64, in: :path
    field :message_id, :i64, in: :path
  end

  params :PageParams do
    field :id, :i64, in: :path
    field :before, :i64, in: :query, optional: true
    field :after, :i64, in: :query, optional: true
  end

  # Messages::ByBotsController#index, reached through routes.rb `scope path: ":bot_key"` under /rooms/:room_id (the room is :id here).
  params :BotMessagesPath do
    field :id, :i64, in: :path
    field :bot_key, :string, in: :path
    field :before, :i64, in: :query, optional: true
    field :after, :i64, in: :query, optional: true
  end

  # The same scope for one message (update) and the boosts under it. No body field: the body is read raw.
  params :BotMessagePath do
    field :id, :i64, in: :path
    field :bot_key, :string, in: :path
    field :message_id, :i64, in: :path
  end

  params :SearchParams do
    field :q, :string, in: :query, optional: true
  end

  # Users::AvatarsController#show: the web path segment is a Rails signed_id token, not a numeric user id.
  params :AvatarPath do
    field :token, :string, in: :path
  end

  # Autocompletable::UsersController#index: the editor's prompt sends `filter`, an autocomplete input sends
  # `query`, and both may name a room the users must belong to.
  params :AutocompleteParams do
    field :filter, :string, in: :query, optional: true
    field :query, :string, in: :query, optional: true
    field :room_id, :i64, in: :query, optional: true
  end

  # Accounts::BotsController#edit and #destroy: the bot id in the path, which `resources :bots` derives (routes.axum.rb).
  params :BotPath do
  end

  params :JoinPath do
    field :join_code, :string, in: :path
  end

  # QrCodeController#show: the url-safe Base64 of the URL to encode.
  params :QrCodePath do
    field :id, :string, in: :path
  end

  params :TransferPath do

    field :id, :string, in: :path
  end

  # MessagesController#create: the room in the path, the submitted message in the form. Rails' form posts the
  # bracketed wire names (`message[body]`), declared with `name:`; the body still reads `params[:body]` (GAPS.md 13).
  # The composer's file post is an XHR multipart body with `message[attachment]` and `message[client_message_id]` and no
  # body, so the body is optional; a text post is urlencoded or multipart, and a group with an :upload reads both.
  params :NewMessage do
    field :id, :i64, in: :path
    field :body, :string, in: :form, name: "message[body]", optional: true
    field :attachment, :upload, in: :form, name: "message[attachment]"
    field :client_message_id, :string, in: :form, name: "message[client_message_id]", optional: true
  end
end
