# frozen_string_literal: true

require "net/http"

# The integration tests' app: a Rack app that sends each request over HTTP to the port (PORT_URL) and hands back the
# port's response, so Rails' own controller tests (the requests, the response assertions, and the database and
# fixture assertions, which read the same SQLite file the port writes) run against the port.
class PortProxy
  HOP = %w[connection keep-alive transfer-encoding upgrade proxy-connection].freeze

  def initialize(url)
    @uri = URI(url)
  end

  # The integration session takes the URL helpers (`session_url`, ...) and the default env from its app's routes and
  # config: the Rails application's, so the tests build the same requests as against Rails.
  def routes = Rails.application.routes
  def env_config = Rails.application.env_config
  def config = Rails.application.config

  def call(env)
    request = Net::HTTPGenericRequest.new(env["REQUEST_METHOD"], true, true, target(env))
    headers(env).each { |name, value| request[name] = value }
    # Net::HTTP would ask for gzip and inflate it; Rack::Test asks for nothing, so neither does the request here.
    request["accept-encoding"] = env["HTTP_ACCEPT_ENCODING"] || "identity"
    body = env["rack.input"]&.read.to_s
    request.body = body unless body.empty?
    response = Net::HTTP.start(@uri.host, @uri.port, read_timeout: 60) { |http| http.request(request) }
    replay_broadcasts
    # The test runs in the executor, so Active Record's query cache is on; a write in this process would clear it, and
    # the port's write in another process cannot, so every request clears it.
    ActiveRecord::Base.connection_pool.connections.each(&:clear_query_cache)
    out = {}
    response.each_header do |name, _|
      next if HOP.include?(name) || name == "content-length"

      values = response.get_fields(name)
      out[name] = name == "set-cookie" ? values : values.join(", ")
    end
    text = response.body.to_s
    if (log = ENV["PROXY_LOG"].presence)
      File.open(log, "a") { |f| f.puts("#{env['REQUEST_METHOD']} #{target(env)} #{headers(env).inspect} body=#{body[0, 300].inspect} -> #{response.code} #{out['location']} #{text[0, 200].inspect}") }
    end
    out["content-length"] = text.bytesize.to_s
    [response.code.to_i, out, [text]]
  end

  private

  TURBO_STREAM = %r{\A<turbo-stream( maintain_scroll="true")? action="([a-z_]+)" target="([^"]*)">(?:<template>(.*)</template>)?</turbo-stream>\z}m

  # A Turbo Stream the port sent is replayed as the Turbo::StreamsChannel call that sends it (broadcast_replace_to,
  # broadcast_append_to, ...), which is what a test's mocha expectation names, and which writes the same tag to the
  # pubsub; anything else (a channel's own JSON) goes to the pubsub as it is.
  def replay_broadcast(stream, message)
    tag = JSON.parse(message) rescue nil
    match = tag.is_a?(String) && TURBO_STREAM.match(tag)
    method = match && :"broadcast_#{match[2]}_to"
    if method && Turbo::StreamsChannel.respond_to?(method)
      options = { target: CGI.unescapeHTML(match[3]) }
      options[:html] = match[4] if match[4]
      options[:attributes] = { maintain_scroll: true } if match[1]
      Turbo::StreamsChannel.public_send(method, stream, **options)
    else
      ActionCable.server.pubsub.broadcast(stream, message)
    end
  end

  # The port's broadcasts during the request (AXUM_DSL_CABLE_LOG, one JSON line each), handed to Action Cable's test
  # pubsub as Rails' own would be, so assert_broadcasts and assert_turbo_stream_broadcasts see them.
  def replay_broadcasts
    log = ENV["CABLE_LOG"].presence or return
    return unless File.exist?(log)

    File.open(log) do |f|
      f.seek(@cable_offset ||= 0)
      f.each_line do |line|
        entry = JSON.parse(line)
        replay_broadcast(entry["stream"], entry["message"])
      end
      @cable_offset = f.pos
    end
  end

  def target(env)
    query = env["QUERY_STRING"].to_s
    path = env["SCRIPT_NAME"].to_s + env["PATH_INFO"].to_s
    query.empty? ? path : "#{path}?#{query}"
  end

  # The request's headers as the test wrote them: HTTP_* (Host included), Content-Type and Content-Length, the scheme a
  # `https!` session asks for, and the client address.
  def headers(env)
    out = {}
    env.each do |key, value|
      next unless key.start_with?("HTTP_") && value.is_a?(String)

      out[key.delete_prefix("HTTP_").downcase.tr("_", "-")] = value
    end
    out["content-type"] = env["CONTENT_TYPE"] if env["CONTENT_TYPE"]
    out["x-forwarded-proto"] = "https" if env["rack.url_scheme"] == "https" || env["HTTPS"] == "on"
    # The test's REMOTE_ADDR (127.0.0.1 unless it sets another, as the banned-IP test does), as the X-Forwarded-For a
    # proxy in front of the port sends (the port trusts it: `set :trust_forwarded_for`).
    out["x-forwarded-for"] ||= env["REMOTE_ADDR"] if env["REMOTE_ADDR"].present?
    out
  end
end
