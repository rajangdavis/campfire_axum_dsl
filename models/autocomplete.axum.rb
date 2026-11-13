model do
  # Autocompletable::UsersController#index: active users whose name matches `pattern`, in Rails'
  # `LOWER(name)` order, 20 at a time. `room_id` narrows the scope to one room the current user is in.
  record :AutocompleteUser do
    field :id, :i64
    field :name, :string
    field :title, :string
    field :avatar_version, :string
  end
end
