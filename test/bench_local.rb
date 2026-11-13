# The local measurement loop (WAVE-PLAN AP0): the release build of this app on a copy of the verification
# repo's real seed, driven by its load generator with its own route contracts (bench/contracts.rb), so a change
# can be measured in minutes instead of a cloud run. It measures this app only, before and after a change; the
# comparison with Rails and Rust is the cloud run (bench-linux.sh). raj-dev is a shared VM: compare runs made
# here with each other, never with the published table.
#
#   ruby test/bench_local.rb CRATE_DIR BINARY [--duration S] [--conc N] [--routes a,b] [--label NAME]
#                                             [--repeat N] [--data-dir NAME=DIR ... | --binary NAME=PATH ...]
#
# `make bench-local` builds both and runs it. Every response is checked against its contract, as in the real
# run; the post_message writes are not reconciled against the database afterwards (validate_acks), which the
# full run still does.
#
# A/B runs. Each `--data-dir NAME=DIR` is a variant: the same binary with its database and files under DIR (a disk
# directory against a tmpfs one, say). Nothing else differs between variants, so the comparison is fair by
# construction: every trial starts from its own fresh copy of the seed, runs the same warm-up and the same load for
# the same time, and the variants alternate A B B A ... over `--repeat` rounds, so a slow drift of the shared VM
# does not fall on one of them. Every trial is printed and kept in the JSON, with each variant's median, min and
# max; the filesystem each DIR is on is recorded beside it. With no --data-dir there is one variant, the system's
# temporary directory.
#
# Binary A/B. Each `--binary NAME=PATH` is a saved release binary (`make bench-local` keeps every build as
# /tmp/campfire_bench_bins/LABEL/campfire) measured against the fresh BINARY under the name --label: the same seed
# copy, warm-up, load and alternating order, only the executable differs. The server is started from the directory
# holding its binary, because it serves public/ and reads pwa/ from the working directory, so a saved binary sits
# beside copies of both (the Makefile saves them together) and each variant runs in its own crate directory. A missing
# binary is refused before anything starts. Binary and data-dir variants are not combined (that would be a matrix, and
# a trial that changes two things says nothing about either); every binary variant uses the system's temporary directory.
require "optparse"
require "etc"
require "tmpdir"
require "shellwords"
verification = File.expand_path("../../once-campfire-verification", __dir__)
require File.join(verification, "bench/contracts")
include BenchmarkSupport

crate, binary = ARGV.shift(2)
abort "usage: ruby test/bench_local.rb CRATE_DIR BINARY [options]" unless crate && binary
options = { duration: 5, conc: 16, routes: "room_show,messages_page,sidebar,search,post_message", label: "run", port: 25140,
            repeat: 1, data_dirs: [], binaries: [] }
OptionParser.new do |parser|
  parser.on("--duration S", Integer) { |v| options[:duration] = v }
  parser.on("--conc N", Integer) { |v| options[:conc] = v }
  parser.on("--routes LIST") { |v| options[:routes] = v }
  parser.on("--label NAME") { |v| options[:label] = v }
  parser.on("--port N", Integer) { |v| options[:port] = v }
  parser.on("--repeat N", Integer) { |v| options[:repeat] = v }
  parser.on("--data-dir NAME=DIR") do |v|
    name, dir = v.split("=", 2)
    abort "--data-dir takes NAME=DIR, got #{v.inspect}" if name.to_s.empty? || dir.to_s.empty?
    options[:data_dirs] << [name, dir]
  end
  parser.on("--binary NAME=PATH") do |v|
    name, path = v.split("=", 2)
    abort "--binary takes NAME=PATH, got #{v.inspect}" if name.to_s.empty? || path.to_s.empty?
    options[:binaries] << [name, path]
  end
end.parse!
abort "--repeat must be at least 1" if options[:repeat] < 1
abort "--data-dir and --binary vary one thing each; use one or the other" unless options[:data_dirs].empty? || options[:binaries].empty?
# A variant is [name, data dir, binary, crate dir]. Saved binaries run from the directory they sit in (their own public/ and pwa/).
variants =
  if options[:binaries].empty?
    (options[:data_dirs].empty? ? [["tmp", Dir.tmpdir]] : options[:data_dirs]).map { |name, dir| [name, dir, binary, crate] }
  else
    options[:binaries].each { |name, path| abort "#{name}: no saved binary at #{path} (run `make bench-local LABEL=#{name}` to save one)" unless File.executable?(path) }
    [[options[:label], Dir.tmpdir, binary, crate]] + options[:binaries].map { |name, path| [name, Dir.tmpdir, File.expand_path(path), File.dirname(File.expand_path(path))] }
  end
abort "variant names must differ" if variants.map(&:first).uniq.size != variants.size
variants.each { |name, dir,| abort "#{name}: #{dir} is not a directory" unless File.directory?(dir) }

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

# contracts.rb reads the seed with the sqlite3 command-line tool; raj-dev has none, so a python3 stand-in.
unless system("command -v sqlite3 >/dev/null 2>&1")
  bin = Dir.mktmpdir("campfire-bench-bin-")
  File.write(File.join(bin, "sqlite3"), "#!/bin/sh\nexec python3 -I #{File.join(__dir__, 'sqlite3_shim.py')} \"$@\"\n")
  File.chmod(0o755, File.join(bin, "sqlite3"))
  ENV["PATH"] = "#{bin}:#{ENV.fetch('PATH')}"
end

# The filesystem a directory is on (ext4, tmpfs, overlay, ...), as `stat -f` reports it; "unknown" when it cannot say.
fs_type = ->(dir) { `stat -f -c %T #{dir.shellescape} 2>/dev/null`.strip.then { |t| t.empty? ? "unknown" : t } }

# One trial: a fresh copy of the seed under `parent`, the server started on it, a warm-up and the measured load per
# route, then the server stopped and the copy removed.
trial = lambda do |parent, binary, crate|
  Dir.mktmpdir("campfire-bench-", parent) do |data|
    prepare_storage(seed, data)
    server_env = { "SECRET_KEY_BASE" => env.fetch("SECRET_KEY_BASE"), "DATABASE_PATH" => File.join(data, "db/production.sqlite3"),
      "ACTIVE_STORAGE_PATH" => File.join(data, "files"), "PORT" => options[:port].to_s, "BIND" => "127.0.0.1",
      # The harness's search contract orders by message id; the app's default is Rails' created_at order (campfire.axum.rb).
      "CAMPFIRE_SEARCH_ORDER_BY_ID" => "1" }
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
      options[:routes].split(",").to_h do |name|
        target = paths.fetch(name) { abort "unknown route #{name}" }
        args = (target ? ["--path", target] : ["--post-room", write_room.to_s, "--csrf", scrape.fetch("csrf").to_s]) + ["--validate", contracts.fetch(name)]
        lg.call("http", "--base", base, "--cookie", cookie, *args, "--conc", "4", "--duration", "1")
        value = lg.call("http", "--base", base, "--cookie", cookie, *args, "--conc", options[:conc].to_s, "--duration", options[:duration].to_s)
        bad = value.fetch("errors") + value.fetch("invalid_responses")
        abort "#{name}: #{bad} failed or invalid responses: #{value.fetch('invalid_reasons', {}).inspect}" unless bad.zero? && value.fetch("ok").positive?
        [name, { rps: value.fetch("rps"), p50_ms: value.dig("latency", "p50_ms"), p99_ms: value.dig("latency", "p99_ms") }]
      end
    ensure
      Process.kill("TERM", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end
end

# A B, then B A, then A B ...: each variant takes the first slot of a round as often as the others.
order = (0...options[:repeat]).flat_map { |round| round.even? ? variants : variants.reverse }
trials = order.each_with_index.map do |(name, dir, bin, bin_crate), i|
  results = trial.call(dir, bin, bin_crate)
  results.each { |route, r| puts format("trial %-3d %-10s %-14s %10.1f rps %8.2f p50 %8.2f p99", i + 1, name, route, r[:rps], r[:p50_ms], r[:p99_ms]) }
  { trial: i + 1, variant: name, results: results }
end

median = ->(xs) { s = xs.sort; s.size.odd? ? s[s.size / 2] : (s[s.size / 2 - 1] + s[s.size / 2]) / 2.0 }
summary = variants.to_h do |name, dir, bin,|
  mine = trials.select { |t| t[:variant] == name }
  routes = mine.first[:results].keys.to_h do |route|
    rps = mine.map { |t| t[:results].fetch(route)[:rps] }
    p99 = mine.map { |t| t[:results].fetch(route)[:p99_ms] }
    [route, { rps_median: median.(rps), rps_min: rps.min, rps_max: rps.max, p99_median_ms: median.(p99), trials: rps.size }]
  end
  [name, { dir: dir, binary: bin, fs: fs_type.(dir), routes: routes }]
end

out = File.join("/tmp/campfire_bench_local", "#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}-#{options[:label]}.json")
write_json(out, { label: options[:label], duration: options[:duration], conc: options[:conc], repeat: options[:repeat], cpus: Etc.nprocessors,
                  order: order.map(&:first), trials: trials, summary: summary })
puts format("%-10s %-10s %-14s %12s %10s %10s %10s", "variant", "fs", "route", "median rps", "min", "max", "p99 ms")
summary.each do |name, s|
  s[:routes].each do |route, r|
    puts format("%-10s %-10s %-14s %12.1f %10.1f %10.1f %10.2f", name, s[:fs], route, r[:rps_median], r[:rps_min], r[:rps_max], r[:p99_median_ms])
  end
end
puts "bench-local: #{options[:label]} written to #{out}"
