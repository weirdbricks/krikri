#!/usr/bin/env crystal

# Crystal Play - Fast Ansible-compatible automation tool
# Main CLI entry point

# Must be required first: redefines top-level puts/print to route
# through CrystalPlay::OutputRouting, which --forks's per-host fan-out
# uses to buffer output per fiber. Everything else in the program still
# writes straight to the real STDOUT (a fiber with no redirect
# registered falls through unchanged) - this only matters once a
# --forks > 1 run is actually in flight.
require "./src/crystal_play/task_executor/output_routing"

require "option_parser"
require "colorize"
require "./src/crystal_play/version"
require "./src/crystal_play/playbook_parser"
require "./src/crystal_play/tag_filter"
require "./src/crystal_play/extra_vars_parser"
require "./src/crystal_play/inventory_parser"
require "./src/crystal_play/task_executor"
require "./src/crystal_play/vault"
require "./src/crystal_play/vault_cli"

# `crystal-ansible vault <subcommand> ...` is a completely separate CLI
# surface from running a playbook - dispatch to it before the main
# OptionParser even runs.
if ARGV[0]? == "vault"
  CrystalPlay::VaultCli.run(ARGV[1..])
  exit
end

# `crystal-ansible __async_run <module> <config_path> <status_path>` is an
# internal-only entry point (not a user-facing subcommand): TaskExecutor's
# async:/poll: support spawns this as a detached background process to run
# a single module and write its result to the job's status file, so the
# job outlives the poll loop (or the whole playbook run) rather than being
# tied to a Fiber in the parent process. See
# TaskExecutor#execute_async/AsyncJobs.
if ARGV[0]? == "__async_run"
  module_name = ARGV[1]
  config_path = ARGV[2]
  status_path = ARGV[3]

  config_json = JSON.parse(File.read(config_path))
  local_host = CrystalPlay::Host.new("localhost")
  result = CrystalPlay::PluginManager.execute_plugin(module_name, config_json, local_host, {} of String => JSON::Any)

  # as_h.dup, not JSON.parse(result.to_json).as_h: only a top-level key is
  # added below, so a shallow copy is equivalent to the round trip, and
  # the round trip's cost scales with the module's whole output.
  result_hash = result.as_h.dup
  result_hash["finished"] = JSON::Any.new(1_i64)

  tmp_path = "#{status_path}.tmp"
  File.write(tmp_path, JSON::Any.new(result_hash).to_json)
  File.rename(tmp_path, status_path)
  File.delete(config_path) rescue nil
  exit
end

# Parse command line arguments
playbook_file = ""
inventory_file = "inventory.ini"
check_mode = false
diff_mode = false
batching_enabled = true
# SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #15: persistent remote
# executor - one long-lived ssh+plugin-daemon session per host instead
# of forking ssh+exec per task. Was opt-in behind --persistent-daemon
# from 0.9.496 through 0.9.499; promoted to default at 0.9.501 based
# on the 10-role real-host benchmark (commit 54da326, ~6.3× mean warm
# speedup) and the absence of regressions across the per-role round
# work documented in README.md / KNOWN_MISSING.md. --no-persistent-daemon
# remains available for parity benchmarking against the old path or
# for hitting specific debug/edge-case scenarios where the per-task
# ssh fork is actually wanted. The per-task path is still used as
# fallback for become:, gather_facts:, batched task groups, remote
# async, and any daemon-connection failure - so dropping the flag never
# reduces functionality, only throughput.
persistent_daemon = true
# real ansible-playbook's default (5) exists because a "fork" there is a
# forked Python interpreter per host - expensive enough that 5 concurrent
# ones is a real resource tradeoff. Here a "fork" is a Crystal fiber
# gated by a channel (see TaskExecutor's per-task host fan-out), doing
# pure SSH I/O wait - nothing about 5 is load-bearing for this
# implementation, so this default diverges from real Ansible's own
# (unlike `gathering`, which stays "implicit" specifically to match it -
# see SUGGESTED_PERFORMANCE_IMPROVEMENTS.md's own item on why that one
# was rejected). The real-host benchmark workflow (CLAUDE.md) should pin
# `--forks 5` explicitly when diffing behavior against real
# ansible-playbook, since interleaving under -v and target-side load
# both change with concurrency even though no single host's own output
# does.
forks = 25
# "implicit" (default, matching ansible-playbook): every play re-gathers
# facts. "smart": each host is gathered at most once per run, so a
# multi-play playbook stops paying N_plays x N_hosts fact round trips.
gathering = "implicit"
verbose = false
limit_hosts = ""
tags = [] of String
skip_tags = [] of String
extra_vars_args = [] of String
vault_password_file = nil
ask_vault_pass = false

begin
  OptionParser.parse do |parser|
    parser.banner = "Usage: crystal-ansible [options] playbook.yml"

    parser.on("-i INVENTORY", "--inventory=INVENTORY", "Specify inventory file") do |inv|
      inventory_file = inv
    end

    parser.on("-c", "--check", "Don't make changes; predict changes instead (dry-run)") do
      check_mode = true
    end

    parser.on("-d", "--diff", "Show file differences when changing files") do
      diff_mode = true
    end

    parser.on("--no-batching", "Disable batching consecutive independent tasks into fewer SSH round trips (on by default since 0.9.63)") do
      batching_enabled = false
    end

    parser.on("--persistent-daemon", "(SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #15, on by default since 0.9.501): keep one persistent ssh+plugin-daemon connection per remote host instead of forking ssh+exec per task, for solo (non-batched, non-become:) remote tasks. become:/batched tasks and remote fact-gathering always use the existing per-task path regardless of this flag. Equivalent to the default; accepted for backward compatibility with playbooks/aliases that set it explicitly.") do
      persistent_daemon = true
    end

    parser.on("--no-persistent-daemon", "Opt out of the default persistent-daemon mode (item #15) and use the per-task ssh-fork path instead. Provided for parity benchmarking against the pre-0.9.501 architecture and for hitting specific edge-case scenarios where the per-task path is actually wanted. The per-task path remains in place as the fallback for become:, gather_facts:, batched task groups, and remote async regardless of this flag.") do
      persistent_daemon = false
    end

    parser.on("-f FORKS", "--forks=FORKS", "Run each task against up to FORKS hosts concurrently (default: 25 - higher than ansible-playbook's own default of 5, since a \"fork\" here is a cheap fiber, not a forked Python interpreter; --forks 5 matches real ansible-playbook's default exactly, --forks 1 restores one-host-at-a-time)") do |f|
      forks = f.to_i? || 25
    end

    parser.on("--gathering=MODE", "Fact gathering policy, matching ansible-playbook: implicit (default, every play re-gathers), explicit (only plays with gather_facts: true), or smart (each host gathered at most once per run; use meta: clear_facts to force a re-gather)") do |mode|
      normalized = mode.strip.downcase
      unless {"implicit", "explicit", "smart"}.includes?(normalized)
        STDERR.puts "Error: --gathering must be 'implicit', 'explicit' or 'smart', got #{mode.inspect}".colorize(:red)
        exit 1
      end
      gathering = normalized
    end

    parser.on("-v", "--verbose", "Verbose output") do
      verbose = true
    end

    parser.on("-l SUBSET", "--limit=SUBSET", "Limit to specific hosts") do |subset|
      limit_hosts = subset
    end

    parser.on("-e EXTRA_VARS", "--extra-vars=EXTRA_VARS", "Set additional variables as key=value, JSON, or @file (highest precedence; repeatable)") do |e|
      extra_vars_args << e
    end
    parser.on("--skip-tags=TAGS", "Only run tasks whose tags do NOT match these") do |t|
      skip_tags = t.split(",").map(&.strip).reject(&.empty?)
    end
    parser.on("-t TAGS", "--tags=TAGS", "Only run tasks with these tags") do |t|
      tags = t.split(",").map(&.strip).reject(&.empty?)
    end

    parser.on("--vault-password-file=FILE", "Vault password file") do |file|
      vault_password_file = file
    end

    parser.on("--ask-vault-pass", "Prompt for the vault password") do
      ask_vault_pass = true
    end

    parser.on("--version", "Show version information") do
      puts CrystalPlay.version_info
      exit
    end

    parser.on("-h", "--help", "Show this help") do
      puts parser
      puts ""
      puts "Examples:"
      puts "  crystal-ansible playbook.yml"
      puts "  crystal-ansible --check --diff playbook.yml"
      puts "  crystal-ansible --no-batching playbook.yml"
      puts "  crystal-ansible --forks 10 playbook.yml"
      puts "  crystal-ansible --gathering smart playbook.yml"
      puts "  crystal-ansible -i inventory.ini playbook.yml"
      puts "  crystal-ansible --tags deploy playbook.yml"
      puts "  crystal-ansible --vault-password-file pass.txt playbook.yml"
      puts ""
      puts "Vault:"
      puts "  crystal-ansible vault encrypt|decrypt|view|encrypt_string|rekey ..."
      exit
    end

    parser.unknown_args do |args|
      if args.size == 1
        playbook_file = args[0]
      else
        puts "Error: Please specify exactly one playbook file"
        puts parser
        exit 1
      end
    end
  end
rescue ex : OptionParser::InvalidOption
  puts "Error: #{ex.message}".colorize(:red)
  puts ""
  puts "Run 'crystal-ansible --help' for usage information"
  exit 1
rescue ex : Exception
  puts "Error: #{ex.message}".colorize(:red)
  exit 1
end

extra_vars = {} of String => JSON::Any
unless extra_vars_args.empty?
  begin
    extra_vars = CrystalPlay::ExtraVarsParser.parse(extra_vars_args)
  rescue ex : CrystalPlay::ExtraVarsParser::Error
    puts "Error: #{ex.message}".colorize(:red)
    exit 1
  end
end

# Validate args
if playbook_file.empty?
  puts "Error: Playbook file is required"
  puts "Usage: crystal-ansible [options] playbook.yml"
  puts "Try 'crystal-ansible --help' for more information"
  exit 1
end

unless File.exists?(playbook_file)
  puts "Error: Playbook file not found: #{playbook_file}".colorize(:red)
  exit 1
end

if password_file = vault_password_file
  CrystalPlay::Vault.password = File.read(password_file).strip
elsif ask_vault_pass
  CrystalPlay::Vault.password = CrystalPlay::VaultCli.prompt_password
end

# Display banner
puts ""
puts CrystalPlay.banner.colorize(:cyan).bold
puts "=" * 70
puts "Playbook: #{playbook_file}".colorize(:white)
if check_mode
  puts "Mode: CHECK (dry-run)".colorize(:yellow).bold
end
if diff_mode
  puts "Diff: ENABLED".colorize(:green)
end
unless batching_enabled
  puts "Batching: DISABLED".colorize(:yellow)
end
if tags.any?
  puts "Tags: #{tags.join(", ")}".colorize(:cyan)
end
if skip_tags.any?
  puts "Skip tags: #{skip_tags.join(", ")}".colorize(:cyan)
end
puts "=" * 70
puts ""

# Parse playbook
playbook = nil
begin
  playbook = CrystalPlay::PlaybookParser.parse(playbook_file)

  if verbose
    stats = CrystalPlay::PlaybookParser.stats(playbook)
    puts "Playbook Statistics:".colorize(:green).bold
    puts "  Plays: #{stats["plays"]}".colorize(:white)
    puts "  Tasks: #{stats["tasks"]}".colorize(:white)
    puts "  Handlers: #{stats["handlers"]}".colorize(:white)
    puts "  Modules used: #{stats["modules_used"]}".colorize(:white)
    puts ""
  end

  # A module with no plugin binary behind it is skipped rather than
  # aborting the run (KNOWN_MISSING.md's role-private-custom-modules
  # scope cut, so a role leaning on its own library/*.py stays
  # benchmarkable). The `validate` warnings below already NAME it ("uses
  # unimplemented plugin: x"), but the run still ended "Playbook
  # execution complete" with exit 0 - a green light to CI for what real
  # ansible-playbook refuses outright with rc=4. Collected here, acted on
  # at the end of the run (see unavailable_modules_found below).
  unavailable_modules_found = CrystalPlay::PlaybookParser.unavailable_modules(playbook)

  # Show warnings
  warnings = CrystalPlay::PlaybookParser.validate(playbook)
  if warnings.any?
    puts "Warnings:".colorize(:yellow).bold
    warnings.each do |warning|
      puts "  ⚠️  #{warning}".colorize(:yellow)
    end
    puts ""
  end
rescue ex
  puts "Error parsing playbook:".colorize(:red).bold
  puts "  #{ex.message}".colorize(:red)
  # rc=4 is real Ansible's dedicated PARSER-ERROR exit code, distinct
  # from 1 (generic error), 2 (failed hosts) and 3 (unreachable).
  # Verified against ansible-core 2.19.4: both an unparseable playbook
  # and a static import whose path references a fact (0.9.549's
  # StaticImportUndefinedError) exit 4, where this engine exited 1.
  # Note the separate "Playbook file not found" check earlier exits 1,
  # matching real Ansible's own 1 for a missing playbook - that case
  # deliberately does NOT come through here.
  exit 4
end

# Parse inventory
inventory = nil
begin
  inventory = CrystalPlay::InventoryParser.parse(inventory_file)

  if verbose
    stats = CrystalPlay::InventoryParser.stats(inventory)
    puts "Inventory Statistics:".colorize(:green).bold
    puts "  Hosts: #{stats["hosts"]}".colorize(:white)
    puts "  Groups: #{stats["groups"]}".colorize(:white)
    puts "  Variables: #{stats["vars"]}".colorize(:white)
    puts ""
  end

  # Show inventory warnings
  inv_warnings = CrystalPlay::InventoryParser.validate(inventory)
  if inv_warnings.any?
    puts "Inventory Warnings:".colorize(:yellow).bold
    inv_warnings.each do |warning|
      puts "  ⚠️  #{warning}".colorize(:yellow)
    end
    puts ""
  end
rescue ex
  puts "Error loading inventory:".colorize(:red).bold
  puts "  #{ex.message}".colorize(:red)
  puts ""
  puts "Please check that your inventory file exists and is properly formatted.".colorize(:yellow)
  puts "Use -i flag to specify a different inventory file.".colorize(:yellow)
  exit 1
end

# At this point inventory is guaranteed to be set
inventory = inventory.not_nil!

if verbose
  puts "Available Hosts:".colorize(:cyan).bold
  inventory.hosts.each do |name, host|
    puts "  - #{host.user}@#{host.connection_host}:#{host.port}".colorize(:white)
  end
  puts ""
end

# Set verbose mode for plugin manager
CrystalPlay::PluginManager.verbose = verbose
CrystalPlay::PluginManager.daemon_enabled = persistent_daemon

# Batch upload plugins to all remote hosts before execution
# This is much more efficient than uploading during task execution
if playbook && inventory
  CrystalPlay::PluginManager.batch_upload_plugins_for_playbook(playbook, inventory, forks)
end

# Execute playbook
all_hosts = [] of CrystalPlay::Host
combined_results = Hash(String, Hash(String, Int32)).new
# Run-scoped fact store, shared by every play's TaskExecutor under
# --gathering smart so a host gathered in one play isn't re-queried in
# the next. nil under the default implicit mode, where each executor
# builds its own per-play store exactly as before.
run_fact_store = gathering == "smart" ? Hash(String, Hash(String, JSON::Any)).new : nil
# Hosts that hard-failed (a task failed without ignore_errors:) in an
# earlier play this run - excluded from every *remaining* play's host
# list too, matching real Ansible's own behavior (a failure removes a
# host from the rest of the whole run, not just the play it happened
# in). TaskExecutor's own halted_hosts is scoped to one play/one
# instance (crystal-play.cr constructs a fresh one per play); this set
# carries that forward across the per-play loop below.
permanently_failed_hosts = Set(String).new

playbook.plays.each_with_index do |play, play_index|
  puts ""
  puts "PLAY [#{play.name}]".colorize(:magenta).bold
  puts "=" * 70
  puts ""

  # Get hosts for this play from inventory, excluding any host that
  # already hard-failed in an earlier play this run.
  matched_hosts = inventory.get_hosts(play.hosts.to_s)

  # --limit further restricts the play's own hosts: pattern to the
  # intersection with whatever it matches - real ansible-playbook's
  # `-l`/`--limit`. Previously parsed into `limit_hosts` but never
  # actually applied anywhere, so it silently ran every play against
  # its full hosts: pattern regardless of --limit.
  unless limit_hosts.empty?
    limit_names = inventory.get_hosts(limit_hosts).map(&.name).to_set
    matched_hosts = matched_hosts.select { |host| limit_names.includes?(host.name) }
  end

  hosts = matched_hosts.reject { |host| permanently_failed_hosts.includes?(host.name) }

  if matched_hosts.empty?
    puts "Skipping play - no hosts match pattern: #{play.hosts}".colorize(:yellow)
    next
  elsif hosts.empty?
    puts "Skipping play - all matching hosts already failed in an earlier play".colorize(:yellow)
    next
  end

  # Track hosts for recap
  all_hosts.concat(hosts)

  if verbose
    # Show connection hosts (IPs) if different from inventory names
    host_display = hosts.map do |host|
      connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
      connection_host
    end.join(", ")
    puts "Hosts in play: #{host_display}".colorize(:cyan)
    puts ""
  end

  # Get tasks for this play
  tasks_to_run = play.tasks

  # Tag selection: --tags/--skip-tags plus the special tag names and the
  # magic `always`/`never` task tags. Note this runs even with NEITHER
  # flag passed, because `tags: never` must be honored on an ordinary
  # invocation - see TagFilter's own comment.
  tasks_before_tag_filter = tasks_to_run.size
  tasks_to_run = CrystalPlay::TagFilter.apply(tasks_to_run, tags, skip_tags)

  if tasks_to_run.empty? && tasks_before_tag_filter > 0
    if tags.any? || skip_tags.any?
      puts "Skipping play - no tasks match tags: #{(tags + skip_tags).join(", ")}".colorize(:yellow)
    else
      puts "Skipping play - every task is tagged 'never'".colorize(:yellow)
    end
    next
  end

  if tasks_to_run.empty?
    puts "Skipping play - no tasks defined".colorize(:yellow)
    next
  end

  # Create task executor with handlers and play vars
  executor = CrystalPlay::TaskExecutor.new(
    hosts: hosts,
    tasks: tasks_to_run,
    handlers: play.handlers,
    check_mode: check_mode,
    diff_mode: diff_mode,
    play_vars: play.vars,
    # --gathering explicit gathers only for plays that actually wrote
    # `gather_facts: true`; an unset gather_facts (which defaults to true
    # under implicit/smart) means "don't" here.
    gather_facts: gathering == "explicit" ? (play.gather_facts_set && play.gather_facts) : play.gather_facts,
    inventory: inventory,
    inventory_path: inventory_file,
    batching_enabled: batching_enabled,
    forks: forks,
    smart_gathering: gathering == "smart",
    fact_store: run_fact_store,
    extra_vars: extra_vars
  )

  # Run tasks
  executor.run

  # Carry any host that hard-failed in this play forward - excluded from
  # every remaining play too, not just the rest of this one. halted_hosts
  # also includes clean meta: end_host/end_play stops (ended_hosts) and
  # failures since cleared via meta: clear_host_errors
  # (cleared_error_hosts) - neither is a real failure, so both are
  # excluded here: real Ansible's own documented behavior for
  # clear_host_errors is explicitly "available for targeting in
  # subsequent plays", and end_host/end_play's own docs are explicit
  # that they don't fail the host either.
  permanently_failed_hosts.concat(executor.halted_hosts - executor.ended_hosts - executor.cleared_error_hosts)

  # Merge this play's per-host stats into the running total (a host can
  # appear in more than one play).
  executor.results.each do |host_name, host_stats|
    if existing = combined_results[host_name]?
      host_stats.each { |key, value| existing[key] = (existing[key]? || 0) + value }
    else
      combined_results[host_name] = host_stats.dup
    end
  end
end

# Summary
puts ""
puts "=" * 70
puts "PLAY RECAP".colorize(:cyan).bold
puts "=" * 70

CrystalPlay::ResultDisplay.show_recap(all_hosts.uniq { |h| h.name }, combined_results)

puts ""

# set_stats: custom stats block - real ansible-playbook only prints this
# when show_custom_stats is enabled (ansible.cfg [defaults] show_custom_stats,
# or its ANSIBLE_SHOW_CUSTOM_STATS env var override) - off by default. This
# codebase has no ansible.cfg INI parsing, so only the env var override is
# honored; the ansible.cfg file setting itself is not read.
show_custom_stats = ["true", "yes", "1", "on"].includes?(ENV["ANSIBLE_SHOW_CUSTOM_STATS"]?.try(&.downcase) || "")
if show_custom_stats && CrystalPlay::CustomStats.any?
  puts "CUSTOM STATS: ".colorize(:cyan).bold
  unless CrystalPlay::CustomStats.global.empty?
    puts "\t#{CrystalPlay::CustomStats.global.to_json}"
  end
  CrystalPlay::CustomStats.per_host_data.each do |host_name, stats|
    puts "\t#{host_name}: #{stats.to_json}"
  end
  puts ""
end

# Deliberately NOT `combined_results.values.any? { failed > 0 }` - the
# recap's own "failed" stat is a historical count that never decreases
# (matching real Ansible's own display stats), but the exit code follows
# a SEPARATE, mutable signal real Ansible tracks (TaskQueueManager's own
# `_failed_hosts` set, which `meta: clear_host_errors` literally pops a
# host out of - see ansible/plugins/strategy/__init__.py's own
# `_execute_meta`). Verified live: real ansible-playbook exits 0 for a
# run whose recap shows `failed=1` on a host that was later cleared via
# clear_host_errors. `permanently_failed_hosts` is exactly that same
# "still failed" signal - it already excludes any host cleared via
# clear_host_errors or cleanly ended via end_host/end_play, and
# accumulates across every play the same way real Ansible's set does.
any_failed = !permanently_failed_hosts.empty?

# SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #15: close any persistent
# daemon connections before either exit path below - a no-op when
# --persistent-daemon was never passed (the Hash it iterates is simply
# empty), so this is safe to call unconditionally.
CrystalPlay::SSHManager.close_all_daemons

if check_mode
  puts "NOTE: Running in check mode - no changes were made".colorize(:yellow).bold
  puts ""
end

# An unavailable module outranks a failed host: real ansible-playbook
# would have refused the playbook at parse time with rc=4 and never run
# anything, so 4 is the more fundamental signal. This engine still RUNS
# the rest of the play (the scope cut's whole point - a role using its
# own library/*.py stays benchmarkable), so the divergence that remains
# is "which tasks ran", not the exit status a caller sees.
unless unavailable_modules_found.empty?
  puts "✗ Playbook execution completed with unavailable modules: #{unavailable_modules_found.join(", ")}".colorize(:red).bold
  puts ""
  exit 4
end

if any_failed
  puts "✗ Playbook execution completed with failures".colorize(:red).bold
  puts ""
  exit 2
end

puts "✓ Playbook execution complete".colorize(:green).bold
puts ""
