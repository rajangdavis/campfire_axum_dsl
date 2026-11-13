server "idfuzz", version: "0.1.0"
params :Up do
  field :file, :upload, in: :form, name: "file"
end
# An upload's content type and metadata, as Active Storage identifies and analyzes it (one line).
post "/id", params: :Up do
  f = params[:file]
  text("#{f&.content_type || ""} #{f&.metadata || ""}")
end
