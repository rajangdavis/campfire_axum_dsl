controller do
  params :UnfurlLink do
    field :url, :string, in: :form, optional: true
  end

  # UnfurlLinksController#create (the composer's paste of a URL): Opengraph::Metadata.from_url(params.require(:url)),
  # `render json:` when it validates, else `head :no_content`. A missing or blank url (`require` wants it present) is
  # Rails' ParameterMissing, a 400.
  def create
    url = params[:url]
    return halt(400, "") if url.nil? || url.to_s.strip.empty?
    found = opengraph_unfurl(url)
    return halt(204, "") if found.nil?
    text(found, content_type: "application/json; charset=utf-8")
  end
end
