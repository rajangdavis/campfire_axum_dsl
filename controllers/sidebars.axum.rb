fragment do
  get "/users/me/sidebar", description: "Your rooms: direct ones, then the shared ones" do
    user = current(:user)
    render :sidebar, locals: { title: "Rooms", directs: direct_rooms_for(user_id: user.id), shared: shared_rooms_for(user_id: user.id) }
  end
end
