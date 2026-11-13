# Rails' own controller tests, against the port

`run.sh [paths under test/ ...]` runs the reference app's `test/controllers` (185 tests) in the parity reference
image (`campfire-reference:app`) with their requests answered by this app:

- `port_proxy.rb` is the integration tests' app: a Rack app that sends each request over HTTP to the port and hands back
  its response. It keeps the Rails application's routes and env config, so URL helpers and signed cookies work, passes
  the test's `REMOTE_ADDR` as `X-Forwarded-For`, and clears Active Record's query cache after every request, because the
  port writes from another process.
- `test_helper.rb` replaces the reference's (which it loads first): fixtures are committed (no transactional tests),
  the tables no fixture covers are emptied before each test, and WebMock allows localhost.
- The port runs on the tests' own SQLite file with `RATE_LIMIT=0 FRONT=0 CAMPFIRE_RESPONSE_CACHE_MB=0` (Rails' test
  environment: a `:null_store` cache, no Thruster) and the test environment's `secret_key_base`.

`PROXY_LOG=/rails/tmp/proxy.log run.sh` logs every proxied request under the test that made it;
`summary.py /tmp/campfire-rails-tests/tests.log` lists the failing tests with their first message.

The port runs with `AXUM_DSL_CABLE_LOG` set, so every broadcast is logged; after each request the proxy replays the
new ones into Action Cable's test pubsub, a Turbo Stream as the `Turbo::StreamsChannel.broadcast_<action>_to` call that
sends it, so `assert_broadcasts`, `assert_turbo_stream_broadcasts` and mocha expectations on those calls see the port's.

Status (2026-11-08): 175 of 185 pass. The 10 left assert on what an HTTP proxy cannot see in the Rails process: enqueued jobs (2), a mock of Action Cable's remote connections (1), raised exceptions under
`show_exceptions: :none` (2), and WebMock/DNS stubs of the port's own outbound requests (5).
