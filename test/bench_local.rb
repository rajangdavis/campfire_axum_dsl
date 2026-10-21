# The local measurement loop (WAVE-PLAN AP0): the release build of this app on a copy of the verification
# repo's real seed, driven by its load generator with its own route contracts (bench/contracts.rb), so a change
# can be measured in minutes instead of a cloud run. It measures this app only, before and after a change; the
# comparison with Rails and Rust is the cloud run (bench-linux.sh). raj-dev is a shared VM: compare runs made
# here with each other, never with the published table.
#
#   ruby test/bench_local.rb CRATE_DIR BINARY [--duration S] [--conc N] [--routes a,b] [--label NAME]
#
# `make bench-local` builds both and runs it. Every response is checked against its contract, as in the real
# run; the post_message writes are not reconciled against the database afterwards (validate_acks), which the
# full run still does.
require "optparse"
require "etc"
require "tmpdir"
verification = File.expand_path("../../once-campfire-verification", __dir__)
require File.join(verification, "bench/contracts")
include BenchmarkSupport

crate, binary = ARGV.shift(2)
abort "usage: ruby test/bench_local.rb CRATE_DIR BINARY [options]" unless crate && binary
options = { duration: 5, conc: 16, routes: "room_show,messages_page,sidebar,search,post_message", label: "run", port: 25140 }
OptionParser.new do |parser|
  parser.on("--duration S", Integer) { |v| options[:duration] = v }
  parser.on("--conc N", Integer) { |v| options[:conc] = v }
  parser.on("--routes LIST") { |v| options[:routes] = v }
  parser.on("--label NAME") { |v| options[:label] = v }
  parser.on("--port N", Integer) { |v| options[:port] = v }
end.parse!

seed = File.join(verification, "fixtures/default")
loadgen = ENV.fetch("LOADGEN", File.join(verification, "loadgen/target/release/loadgen"))
abort "no seed at #{seed} (bin/seed in once-campfire-verification)" unless File.file?(File.join(seed, "labels.json"))
abort "no load generator at #{loadgen}" unless File.executable?(loadgen)
labels = JSON.parse(File.read(File.join(seed, "labels.json")))
env = File.readlines(File.join(seed, "reference.env"), chomp: true).reject { |l| l.empty? || l.start_with?("#") }.to_h { |l| l.split("=", 2) }
room = Integer(labels.fetch("rooms.watercooler"))
write_room = Integer(labels.fetch("rooms.hq"))
base = "http://127.0.0.1:#{options[:port]}"
lg = ->(*args) { JSON.parse(run(loadgen, *args)) }

Dir.mktmpdir("campfire-bench-") do |data|
  prepare_storage(seed, data)
  # contracts.rb reads the seed with the sqlite3 command-line tool; raj-dev has none, so a python3 stand-in.
  unless system("command -v sqlite3 >/dev/null 2>&1")
    bin = File.join(data, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "sqlite3"), "#!/bin/sh\nexec python3 -I #{File.join(__dir__, 'sqlite3_shim.py')} \"$@\"\n")
    File.chmod(0o755, File.join(bin, "sqlite3"))
    ENV["PATH"] = "#{bin}:#{ENV.fetch('PATH')}"
  end
  server_env = { "SECRET_KEY_BASE" => env.fetch("SECRET_KEY_BASE"), "DATABASE_PATH" => File.join(data, "db/production.sqlite3"),
    "ACTIVE_STORAGE_PATH" => File.join(data, "files"), "PORT" => options[:port].to_s, "BIND" => "127.0.0.1" }
  log = File.join(data, "server.log")
  pid = spawn(server_env, File.expand_path(binary), chdir: crate, out: log, err: log)
  begin
    deadline = Time.now + 30
    until (Net::HTTP.get_response(URI("#{base}/up")).code == "200" rescue false)
      abort "server did not start:\n#{File.read(log)}" if Time.now > deadline || Process.waitpid(pid, Process::WNOHANG)
      sleep 0.1
    end
    cookie = lg.call("login", "--base", base, "--email", labels.fetch("emails.david"), "--password", labels.fetch("passwords.all")).fetch("cookie")
    scrape = lg.call("scrape", "--base", base, "--cookie", cookie, "--room", room.to_s)
    contracts = BenchmarkContracts.prepare(base, cookie, File.join(data, "db/production.sqlite3"), labels, scrape.fetch("css"),
      File.join(data, "contracts")).fetch(:contracts)
    paths = { "room_show" => "/rooms/#{room}", "messages_page" => "/rooms/#{room}/messages?before=#{labels.fetch('messages.busy_060')}",
      "sidebar" => "/users/me/sidebar", "search" => "/searches?q=coffee", "post_message" => nil }
    results = options[:routes].split(",").to_h do |name|
      target = paths.fetch(name) { abort "unknown route #{name}" }
      args = (target ? ["--path", target] : ["--post-room", write_room.to_s, "--csrf", scrape.fetch("csrf").to_s]) + ["--validate", contracts.fetch(name)]
      lg.call("http", "--base", base, "--cookie", cookie, *args, "--conc", "4", "--duration", "1")
      value = lg.call("http", "--base", base, "--cookie", cookie, *args, "--conc", options[:conc].to_s, "--duration", options[:duration].to_s)
      bad = value.fetch("errors") + value.fetch("invalid_responses")
      abort "#{name}: #{bad} failed or invalid responses: #{value.fetch('invalid_reasons', {}).inspect}" unless bad.zero? && value.fetch("ok").positive?
      [name, { rps: value.fetch("rps"), p50_ms: value.dig("latency", "p50_ms"), p99_ms: value.dig("latency", "p99_ms") }]
    end
    out = File.join("/tmp/campfire_bench_local", "#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}-#{options[:label]}.json")
    write_json(out, { label: options[:label], duration: options[:duration], conc: options[:conc], cpus: Etc.nprocessors, results: results })
    puts format("%-14s %10s %8s %8s", "route", "rps", "p50 ms", "p99 ms")
    results.each { |name, r| puts format("%-14s %10.1f %8.2f %8.2f", name, r[:rps], r[:p50_ms], r[:p99_ms]) }
    puts "bench-local: #{options[:label]} written to #{out}"
  ensure
    Process.kill("TERM", pid) rescue nil
    Process.wait(pid) rescue nil
  end
end
