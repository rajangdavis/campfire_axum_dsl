# The route table: verb + path -> controller#action. The action bodies and their filters live in
# controllers/; this file says which path reaches which def. `use_dsl "routes.axum.rb"` in campfire.axum.rb.
fragment do
  resources :rooms, only: [:show], params: :RoomPath, cache: :private, controller: "Rooms",
            description: "A room: its newest 40 messages, oldest first"

  get "/rooms/:id/@:message_id", controller: "Rooms", action: :show_at, params: :RoomAtPath, cache: :private,
      description: "A room opened at one message: the 40 before it, it, the 40 after"
  get "/rooms/:id/messages", controller: "Rooms", action: :messages_page, params: :PageParams, cache: :private,
      description: "The 40 messages before one, as a fragment (204 when there are none)"
  post "/rooms/:id/messages", controller: "Rooms", action: :post_message, params: :NewMessage,
       description: "Post a message to the room and stream it back"

  # AccountsController's settings pages. Each is a Rails resource verb, with the action body in its controller and that
  # controller's `before :ensure_can_administer` still in force (the table and the controllers stay in step at compile time).
  # Rails: `resource :account do scope module: "accounts" do resources :users; resources :bots ... end end`. The bots are rows
  # of `users` (`model: :User`), so their :id is the users table's primary key; each action names its own params group and text.
  scope path: "account" do
    resources :bots, only: %i[index new edit create update destroy], controller: "Accounts::Bots", model: :User,
              params: { edit: :BotPath, create: :BotForm, update: :BotUpdate, destroy: :BotPath },
              description: { index: "Chat bots", new: "New chat bot", edit: "Edit a chat bot",
                             create: "Create a chat bot and go back to the bots",
                             update: "Save a chat bot and go back to the bots", destroy: "Deactivate a chat bot" }

    resources :users, only: %i[update destroy], controller: "Accounts::Users",
              params: { update: :AccountUserRole, destroy: :AccountUserPath },
              description: { update: "Make a person an administrator or a member", destroy: "Remove a person from the account" }
    # The index as the people page's lazy frame asks for it, in two spellings (Accounts::UsersController#index).
    get "/users.turbo_stream", controller: "Accounts::Users", action: :index_stream, params: :AccountUsersPage,
        description: "One page of the account's people, as a turbo stream"
    get "/users", controller: "Accounts::Users", action: :index, params: :AccountUsersFormat,
        description: "One page of the account's people, when the format asks for a turbo stream"
  end

  get "/account/custom_styles/edit", controller: "Accounts::CustomStyles", action: :edit, description: "Custom styles"
  patch "/account/custom_styles", controller: "Accounts::CustomStyles", action: :update, params: :CustomStylesUpdate,
        also: [:put], description: "Save the account's custom CSS and go back to it with a notice"

  post "/account/join_code", controller: "Accounts::JoinCodes", action: :create,
       description: "Give the account a new join code and go back to its settings"

  delete "/account/logo", controller: "Accounts::Logos", action: :destroy,
         description: "Remove the account's logo and go back to its settings"

  put "/account/bots/:bot_id/key", controller: "Accounts::Bots::Keys", action: :update, params: :BotKeyPath,
      also: [:patch], description: "Give a chat bot a new key"

  get "/qr_code/:id", controller: "QrCode", action: :show, params: :QrCodePath, skip: [:authenticate],
      description: "A QR code SVG for a url-safe Base64 URL"

  post "/unfurl_link", controller: "UnfurlLinks", action: :create, params: :UnfurlLink,
       description: "OpenGraph metadata for a pasted URL, as JSON"

  get "/up", controller: "Health", action: :show, skip: [:authenticate, :allow_browser], description: "Health check"

  get "/webmanifest.json", controller: "Pwa", action: :manifest, skip: [:authenticate], description: "Web app manifest"
  get "/service-worker.js", controller: "Pwa", action: :service_worker, skip: [:authenticate],
      description: "Service worker"

  get "/users/me/sidebar", controller: "Sidebars", action: :show, cache: :private,
      description: "Your rooms: direct ones, then the shared ones"

  post "/searches", controller: "Searches", action: :create, params: :NewSearch,
       description: "Remember a search and go to its results"
  get "/searches", controller: "Searches", action: :index, params: :SearchParams, cache: :private,
      description: "Messages in your rooms that match q, newest 100, oldest first"
  delete "/searches/clear", controller: "Searches", action: :clear, description: "Forget your recent searches"

  get "/account/logo", controller: "Logos", action: :show, params: :LogoParams, skip: [:authenticate],
      description: "The account logo (PNG variant)"

  get "/autocompletable/users", controller: "Autocomplete", action: :index, params: :AutocompleteParams,
      description: "Users whose names match a mention query"
  get "/autocompletable/users.json", controller: "Autocomplete", action: :index_json, params: :AutocompleteParams,
      description: "Users whose names match a mention query, as JSON"

  post "/users/:id/ban", controller: "People", action: :ban, params: :UserBanPath,
       description: "Ban a person: sign them out, block their IPs and remove their messages"
  delete "/users/:id/ban", controller: "People", action: :unban, params: :UserBanPath,
         description: "Lift a person's ban"
  delete "/users/:token/avatar", controller: "People", action: :destroy_avatar, params: :AvatarOwnerPath,
         description: "Remove your avatar"
  get "/users/:token/avatar", controller: "Avatars", action: :show, params: :AvatarPath,
      description: "A user's processed avatar (Rails signed_id token)"

  patch "/users/me/profile", controller: "Profiles", action: :update, params: :ProfileUpdate, also: [:put],
        description: "Save the profile (and an avatar) and go back to it with a notice"
  get "/users/me/profile", controller: "Profiles", action: :show, description: "Your profile"

  # Rails: `resources :push_subscriptions` under `scope defaults: { user_id: "me" }`, with test_notifications nested in it.
  scope path: "users/me" do
    resources :push_subscriptions, only: %i[index create destroy], controller: "PushSubscriptions",
              params: { create: :NewPushSubscription, destroy: :PushSubscriptionPath },
              description: { index: "Your Web Push subscriptions", create: "Register this browser's Web Push subscription",
                             destroy: "Remove one of your Web Push subscriptions" }
    post "/push_subscriptions/:push_subscription_id/test_notifications", controller: "PushSubscriptions",
         action: :test_notification, params: :PushSubscriptionTestPath,
         description: "Send a test notification to one of your subscriptions"
  end

  get "/session/new", controller: "Sessions", action: :new, params: :SessionNewParams, skip: [:authenticate],
      description: "The login form"
  post "/session", controller: "Sessions", action: :create, params: :Login, skip: [:authenticate],
       description: "Log in: start a session and set the session_token cookie"
  delete "/session", controller: "Sessions", action: :destroy, params: :Logout,
         description: "Log out: delete the session row and the cookie"
  get "/", controller: "Sessions", action: :root, description: "Your first room, or a note that you have none"

  get "/join/:join_code", controller: "Users", action: :new, params: :JoinPath, skip: [:authenticate],
      description: "The join form for an account's join code"
  post "/join/:join_code", controller: "Users", action: :create, params: :JoinCreate, skip: [:authenticate],
       description: "Create a person from the join form, sign them in and go to a room"
  get "/session/transfers/:id", controller: "Users", action: :show_transfer, params: :TransferPath,
      skip: [:authenticate], description: "The page that submits a session transfer"
  put "/session/transfers/:id", controller: "Users", action: :update_transfer, params: :TransferPath, also: [:patch],
      skip: [:authenticate], description: "Complete a session transfer and sign in"
  get "/users/:id", controller: "Users", action: :show, params: :UserPath, description: "A user's page"

  get "/first_run", controller: "FirstRuns", action: :show, skip: [:authenticate],
      description: "The set-up form of an install with no account"
  post "/first_run", controller: "FirstRuns", action: :create, params: :FirstRunCreate, skip: [:authenticate],
       description: "Create the account, its administrator and first room, and sign in"

  get "/account/edit", controller: "Accounts", action: :edit, description: "Account settings"
  patch "/account", controller: "Accounts", action: :update, params: :AccountUpdate, also: [:put],
        description: "Save the account (its name, its logo or the room-creation switch) and go back to its settings"

  get "/rooms/:id/involvement", controller: "RoomFragments", action: :involvement, params: :RoomPath, cache: :private,
      description: "The room's notification button, as a Turbo frame"
  put "/rooms/:id/involvement", controller: "RoomFragments", action: :update_involvement, params: :InvolvementUpdate,
      also: [:patch], description: "Set the room's notification level and go back to the button"
  get "/rooms/:id/refresh", controller: "RoomFragments", action: :refresh, params: :RefreshPath,
      description: "Messages created or updated since a time, as Turbo Streams"
  get "/rooms/:id/messages/:message_id", controller: "RoomFragments", action: :message, params: :MessagePath,
      cache: :private, description: "One message of a room"

  get "/rails/active_storage/blobs/redirect/:signed_blob_id/*filename", controller: "ActiveStorage",
      action: :blob_redirect, params: :BlobPath, skip: [:authenticate, :allow_browser],
      description: "A blob's original file: a redirect to its disk service URL"
  get "/rails/active_storage/representations/redirect/:signed_blob_id/:variation_key/*filename",
      controller: "ActiveStorage", action: :representation_redirect, params: :RepresentationPath,
      skip: [:authenticate, :allow_browser], description: "A blob's processed variant: a redirect to its disk service URL"
  get "/rails/active_storage/disk/:encoded_key/*filename", controller: "ActiveStorage", action: :disk,
      params: :DiskPath, skip: [:authenticate, :allow_browser], description: "A blob's file from the disk service"
  post "/rails/active_storage/direct_uploads", controller: "ActiveStorage", action: :direct_upload,
       params: :DirectUpload, skip: [:authenticate], description: "Direct upload: create the blob and sign its upload URL"
  put "/rails/active_storage/disk/:encoded_token", controller: "ActiveStorage", action: :disk_upload,
      params: :DiskUpload, skip: [:authenticate], description: "Direct upload to the disk service"

  # The bot API (controllers/bot_messages.axum.rb; the bot's create and deletes are MessagesController's).
  get "/rooms/:id/:bot_key/messages", controller: "BotMessages", action: :index, params: :BotMessagesPath,
      description: "A room's messages as JSON for a bot, with X-Total-Count and Link pagination headers"
  put "/rooms/:id/:bot_key/messages/:message_id", controller: "BotMessages", action: :update, params: :BotMessagePath,
      also: [:patch], description: "Replace a message's body with the raw request body, for a bot"
  post "/rooms/:id/:bot_key/messages/:message_id/boosts", controller: "BotMessages", action: :add_boost,
       params: :BotMessagePath, description: "Boost a message with the raw request body, for a bot"

  get "/rooms/:id/messages/:message_id/edit", controller: "Messages", action: :edit, params: :MessagePath,
      cache: :private, description: "The edit form of one message, as a Turbo frame"
  patch "/rooms/:id/messages/:message_id", controller: "Messages", action: :update, params: :UpdateMessage,
        also: [:put], description: "Save an edited message and go back to it"
  delete "/rooms/:id/messages/:message_id", controller: "Messages", action: :destroy, params: :MessagePath,
         description: "Delete a message and remove it from the page"
  get "/messages/:message_id/boosts", controller: "Messages", action: :boosts, params: :MessageBoostsPath,
      description: "A message's boosts, as a Turbo frame"
  get "/messages/:message_id/boosts/new", controller: "Messages", action: :new_boost, params: :MessageBoostsPath,
      cache: :private, description: "The new-boost form of a message, as a Turbo frame"
  post "/messages/:message_id/boosts", controller: "Messages", action: :add_boost, params: :NewBoost,
       description: "Boost a message and show its boosts"
  delete "/messages/:message_id/boosts/:id", controller: "Messages", action: :destroy_boost, params: :MessageBoostPath,
         description: "Delete one of your boosts"
  post "/rooms/:id/:bot_key/messages", controller: "Messages", action: :create_by_bot, params: :BotMessagesPath,
       description: "Post the raw request body to a room as a message, for a bot"
  delete "/rooms/:id/:bot_key/messages/:message_id", controller: "Messages", action: :destroy_by_bot,
         params: :BotMessagePath, description: "Delete a message, for a bot"
  delete "/rooms/:id/:bot_key/messages/:message_id/boosts/:boost_id", controller: "Messages",
         action: :destroy_boost_by_bot, params: :BotBoostPath, description: "Delete one of a bot's boosts"

  # The room forms (controllers/room_forms.axum.rb): Rooms::OpensController, ClosedsController and DirectsController.
  get "/rooms", controller: "RoomForms", action: :index, description: "Go to your newest room"
  delete "/rooms/:id", controller: "RoomForms", action: :destroy, params: :RoomPath,
         description: "Delete a room with its messages and take it out of every sidebar"
  get "/rooms/opens/new", controller: "RoomForms", action: :new_open, description: "The new open-room form"
  post "/rooms/opens", controller: "RoomForms", action: :create_open, params: :NewRoom,
       description: "Create an open room, put it in every sidebar and go to it"
  get "/rooms/opens/:id", controller: "RoomForms", action: :show_open, params: :RoomPath,
      description: "Go to the room (a open room's own address)"
  get "/rooms/opens/:id/edit", controller: "RoomForms", action: :edit_open, params: :RoomPath,
      description: "The open-room settings form"
  patch "/rooms/opens/:id", controller: "RoomForms", action: :update_open, params: :OpenRoomUpdate, also: [:put],
        description: "Save an open room's name, opening a closed one, and go to it"
  get "/rooms/closeds/new", controller: "RoomForms", action: :new_closed, description: "The new closed-room form"
  post "/rooms/closeds", controller: "RoomForms", action: :create_closed, params: :NewClosedRoom,
       description: "Create a closed room for the people checked and go to it"
  get "/rooms/closeds/:id", controller: "RoomForms", action: :show_closed, params: :RoomPath,
      description: "Go to the room (a closed room's own address)"
  get "/rooms/closeds/:id/edit", controller: "RoomForms", action: :edit_closed, params: :RoomPath,
      description: "The closed-room settings form"
  patch "/rooms/closeds/:id", controller: "RoomForms", action: :update_closed, params: :ClosedRoomUpdate,
        also: [:put], description: "Save a closed room's name and members and go to it"
  get "/rooms/directs/new", controller: "RoomForms", action: :new_direct, description: "The new ping form"
  post "/rooms/directs", controller: "RoomForms", action: :create_direct, params: :NewDirectRoom,
       description: "Open the ping with the people chosen, creating it the first time"
  get "/rooms/directs/:id/edit", controller: "RoomForms", action: :edit_direct, params: :RoomPath,
      description: "The ping settings form"
  delete "/rooms/directs/:id", controller: "RoomForms", action: :destroy_direct, params: :RoomPath,
         description: "Delete a ping with its messages and take it out of every sidebar"
end
