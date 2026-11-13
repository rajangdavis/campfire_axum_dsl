server "variantfuzz", version: "0.1.0"
params :Case do
  field :src, :string, in: :query
  field :name, :string, in: :query
  field :w, :i64, in: :query
  field :h, :i64, in: :query
end
# image_variant of one input, stored under /work/store; answers the stored key, or "ERROR".
get "/v", params: :Case do
  variant = image_variant(params[:src], params[:name], params[:w], params[:h])
  key = if variant.nil?
    "ERROR"
  else
    variant.store("/work/store")
  end
  text(key)
end
