# frozen_string_literal: true

# Rails' test/test_helper.rb (mounted as test_helper_rails.rb), then what running it against the port needs:
#   - the integration tests' app is PortProxy, which sends every request to the port (PORT_URL);
#   - fixtures are committed (no transactional tests), because the port reads the database from another process;
#     the tables no fixture file covers are emptied before each test, which is what the rolled-back transaction did;
#   - WebMock lets the proxy reach the port on localhost.
require_relative "test_helper_rails"
require_relative "port_proxy"

ActionDispatch::IntegrationTest.app = PortProxy.new(ENV.fetch("PORT_URL"))

class ActiveSupport::TestCase
  self.use_transactional_tests = false

  FIXTURE_TABLES = Dir[Rails.root.join("test/fixtures/**/*.yml")].map do |path|
    path.delete_prefix("#{Rails.root.join('test/fixtures')}/").delete_suffix(".yml").tr("/", "_")
  end.freeze

  setup do
    connection = ActiveRecord::Base.connection
    (connection.tables - FIXTURE_TABLES - %w[schema_migrations ar_internal_metadata]).each do |table|
      connection.execute("DELETE FROM #{connection.quote_table_name(table)}")
    end
    connection.execute("DELETE FROM message_search_index")
    connection.execute("DELETE FROM sqlite_sequence") if connection.table_exists?("sqlite_sequence")
    WebMock.disable_net_connect!(allow_localhost: true)
    File.open(ENV["PROXY_LOG"], "a") { |f| f.puts("## #{self.class.name}##{name}") } if ENV["PROXY_LOG"].present?
  end
end

# SessionTestHelper#parsed_cookies builds a cookie jar from the integration request, whose env has no
# key generator when the app is the proxy: the Rails application's env config supplies it, as it does for Rails.
module SessionTestHelper
  def parsed_cookies
    ActionDispatch::Cookies::CookieJar.build(ActionDispatch::Request.new(request.env.merge(Rails.application.env_config)), cookies.to_hash)
  end
end
