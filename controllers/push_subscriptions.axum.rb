controller do

  layout_locals do
    signed_in = true
    user_id = current_user.id
    user_name = current_user.name
    logo_version = account_logo_version || ""
  end

  def index
    flags = current_flags
    subscriptions = push_subscriptions_for(user_id: current_user.id)
    back_room_id = last_form_room_id(current_user.id, cookie(:last_room, signed: false).to_s.to_i)
    body_class = "#{flags.admin == 1 ? "admin" : ""}#{flags.logo == 1 ? " account-has-logo" : ""}".strip
    render :push_subscriptions, locals: { title: "Push notification subscriptions" }
  end

  # --- users/push_subscriptions#create, #destroy and test_notifications#create ----------------------------------------

  params :NewPushSubscription do
    field :endpoint, :string, in: :form, name: "push_subscription[endpoint]", default: ""
    field :p256dh_key, :string, in: :form, name: "push_subscription[p256dh_key]", default: ""
    field :auth_key, :string, in: :form, name: "push_subscription[auth_key]", default: ""
  end

  # Users::PushSubscriptionsController#create: an existing subscription with the same three values is touched when it
  # still passes the validations (200, else 422); a new one is created with the request's User-Agent (200, or 422 when
  # it does not validate). Both answers are `head`: an empty body.
  def create
    valid = push_endpoint_valid(endpoint: params[:endpoint]) == 1
    existing = own_push_subscription(user_id: current_user.id, endpoint: params[:endpoint], p256dh_key: params[:p256dh_key], auth_key: params[:auth_key])
    return halt(422, "") unless valid
    fresh = existing.nil?
    if fresh
      create_push_subscription(user_id: current_user.id, endpoint: params[:endpoint], p256dh_key: params[:p256dh_key], auth_key: params[:auth_key], user_agent: user_agent)
    end
    touch_push_subscription(id: existing.nil? ? 0 : existing.id) # id 0 matches nothing
    halt(200, "")
  end

  # The subscription id in the path is derived by `resources :push_subscriptions` (routes.axum.rb).
  params :PushSubscriptionPath do
  end

  # Users::PushSubscriptionsController#destroy: `@push_subscriptions.destroy_by(id:)` (another person's id is a no-op),
  # then redirect_to user_push_subscriptions_url.
  def destroy
    delete_own_push_subscription(user_id: current_user.id, id: params[:id])
    redirect("/users/me/push_subscriptions")
  end

  params :PushSubscriptionTestPath do
    field :push_subscription_id, :i64, in: :path
  end

  # Users::PushSubscriptions::TestNotificationsController#create: `Current.user.push_subscriptions.find` (404), the
  # "Campfire Test" notification delivered, then redirect_to user_push_subscriptions_url. The port sends no Web Push
  # (GAPS): the lookup and the answer are Rails'.
  def test_notification
    found = own_push_subscription_id(user_id: current_user.id, id: params[:push_subscription_id])
    return html(file_text(:page_404), status: 404, content_type: "text/html; charset=UTF-8") if found.nil?
    redirect("/users/me/push_subscriptions")
  end
end
